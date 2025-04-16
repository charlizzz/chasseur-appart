ARG USER=www-data
ARG ENV=production
ARG NODE_VERSION=20
ARG PHP_CONTAINER=8.4-fpm-bullseye
ARG THEME_NAME=montheme


######################### Composer Part ##########################
FROM composer AS composer
WORKDIR /app
COPY composer.* .

FROM composer AS composer-production
RUN --mount=type=cache,target=/tmp/cache --mount=type=secret,id=composer_auth,dst=/app/auth.json composer install --no-ansi --no-dev --no-interaction --no-progress --no-scripts --classmap-authoritative

FROM composer AS composer-staging-refonte
RUN --mount=type=cache,target=/tmp/cache --mount=type=secret,id=composer_auth,dst=/app/auth.json composer install --no-ansi --no-dev --no-interaction --no-progress --no-scripts --classmap-authoritative

FROM composer AS composer-staging
RUN --mount=type=cache,target=/tmp/cache --mount=type=secret,id=composer_auth,dst=/app/auth.json composer install --no-ansi --no-dev --no-interaction --no-progress --no-scripts --classmap-authoritative

FROM composer AS composer-development
RUN --mount=type=cache,target=/tmp/cache --mount=type=secret,id=composer_auth,dst=/app/auth.json composer install --no-interaction --no-scripts

FROM composer-${ENV} AS composer-custom
######################### Composer End Part #####################

############# Node Part (should contain "npm run build" at this stage) ###########
FROM node:${NODE_VERSION} AS node
WORKDIR /var/www
COPY web/app/themes web/app/themes/
COPY package*.json .

FROM node AS node-development
RUN npm i

FROM node AS node-staging-refonte
RUN npm ci && npm cache clean --force

FROM node AS node-staging
RUN npm ci && npm cache clean --force

FROM node AS node-production
RUN npm ci && npm cache clean --force

FROM node-${ENV} AS node-custom
############################### Node End Part #############################


FROM php:${PHP_CONTAINER} AS base
ARG ENV
ARG THEME_NAME
ARG USER
ENV ENV=${ENV}
WORKDIR /var/www
RUN apt-get update && apt-get install --no-install-recommends --no-install-suggests -y \
    wget curl sendmail openssh-client git jq supervisor nginx \
    unzip zip libzip-dev libcurl4-openssl-dev libwebp-dev libfreetype6-dev \
    libjpeg62-turbo-dev libpng-dev libgmp-dev libldap2-dev libonig-dev \
    libicu-dev libtidy-dev libxslt-dev libbz2-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-install bcmath curl gmp gd intl mbstring \
    opcache bz2 mysqli pdo_mysql zip xml tidy xsl \
# configure gd
&& docker-php-ext-configure gd --with-freetype=/usr/include/freetype2 --with-jpeg=/usr/include/
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
  # https://www.php.net/manual/en/errorfunc.constants.php
  # https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
  echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
  echo 'display_errors = Off'; \
  echo 'display_startup_errors = Off'; \
  echo 'log_errors = On'; \
  echo 'error_log = /var/log/php_error.log'; \
  echo 'log_errors_max_len = 1024'; \
  echo 'ignore_repeated_errors = On'; \
  echo 'ignore_repeated_source = Off'; \
  echo 'html_errors = Off'; \
} > $PHP_INI_DIR/conf.d/error-logging.ini
# conf nginx
COPY .system/nginx/content /usr/share/nginx/html
COPY .system/nginx /etc/nginx/
RUN mv /etc/nginx/nginx-${ENV}.conf /etc/nginx/nginx.conf && \
  mv $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini \
  && ln -s /etc/nginx/sites-available/${ENV}.conf /etc/nginx/sites-enabled/${ENV}
# config php
COPY .system/php/php.ini $PHP_INI_DIR/conf.d/wp.ini
# config fpm
COPY .system/php/php-fpm-${ENV}.conf /usr/local/etc/php-fpm.conf
COPY .system/www.conf /usr/local/etc/php-fpm.d/www.conf
# copy global conf files
COPY .system/supervisord-debian.conf /etc/supervisor/conf.d/supervisord.conf
# bring back the wordpress core and all the dependencies from composer installed in the web repo
COPY --chown=${USER} --from=composer-custom /app .
COPY --chown=${USER} --from=node-custom /var/www/web/app/themes/${THEME_NAME}/node_modules web/app/themes/${THEME_NAME}/node_modules
RUN chown -R ${USER}: /var/log
EXPOSE 80 443 9000



FROM base AS development
ARG USER
ARG NODE_VERSION
ENV NODE_VERSION=${NODE_VERSION}
# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp \
# Install Xdebug & nano
  && pecl install xdebug && docker-php-ext-enable xdebug \
  && apt-get update && apt-get install -y nano
# copy composer binary
COPY --chown=${USER} --from=composer-custom /usr/bin/composer /usr/bin/composer
# Get NodeJS
COPY --chown=${USER} --from=node-custom /usr/local/bin /usr/local/bin
# Get npm
COPY --chown=${USER} --from=node-custom /usr/local/lib/node_modules /usr/local/lib/node_modules
# conf nano
COPY --chown=${USER} .system/nanorc /root/.nanorc
# config php for dev
COPY .system/php/php-${ENV}.ini $PHP_INI_DIR/conf.d/php-${ENV}.ini
COPY --chown=${USER} . .
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]



FROM base AS production
COPY --chown=${USER} . .
# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini
# Permet de démarrer nginx & php-fpm
CMD ["/usr/bin/supervisord", "-n","-c", "/etc/supervisor/conf.d/supervisord.conf"]
