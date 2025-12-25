# RunCloud - Bash scripts

Author: @khoipro, alongs with Copilot.

The collection of helpful bash scripts to help you manage servers better. Written by me with Copilot suggestions. Tested.

## Features
- [Install ioncube]([url](https://github.com/codetot-web/runcloud-bash-scripts/blob/main/README.md#install-ioncube))
- [Migration WP Site]([url](https://github.com/codetot-web/runcloud-bash-scripts/blob/main/README.md#migration-wp-site))

## Requirements
- OpenLitespeed/Nginx
- Ubuntu 20, 22 or 24 version

## Changelog
- [x] Install ioncube for all PHP versions - OpenLitespeed
- [x] Install ioncube for all PHP versions - nginx
- [x] Migration script for WordPress (server to server)

## Install Ioncube

**Login as root** to run those commands.

```bash
wget https://github.com/codetot-web/runcloud-bash-scripts/blob/main/install-ioncube.sh
chmod +x install-ioncube.sh
./install-ioncube.sh
```

The sample result:

```bash
root@ubuntu:~# ./install-ioncube.sh
Downloading ionCube loaders...
Installing ionCube for PHP 7.4...
⚠️ Skipping PHP 8.0: loader file not found.
Installing ionCube for PHP 8.1...
Installing ionCube for PHP 8.2...
Installing ionCube for PHP 8.3...
Installing ionCube for PHP 8.4...
Restarting OpenLiteSpeed services...
Verifying ionCube installation...
Cannot load the ionCube PHP Loader - it was already loaded
ionCube Loader
the ionCube PHP Loader + ionCube24
ionCube not loaded for PHP 80
ionCube Loader
the ionCube PHP Loader
ionCube Loader
the ionCube PHP Loader
ionCube Loader
the ionCube PHP Loader
ionCube Loader
the ionCube PHP Loader
✅ ionCube installation completed for all detected PHP versions.
```

## Migration WP Site

Login as `runcloud` or any system user (not require `root`)

```bash
cd /home/runcloud/
wget https://github.com/codetot-web/runcloud-bash-scripts/blob/main/wp-migration.sh
chmod +x wp-migration.sh
```
### Sample 1: Same application, only different server

```bash
./wp-migration.sh runcloud@sample.codetot.com:22 codetot-app
```

### Sample 2: Different appname

```bash
./wp-migration.sh ecohome@sample.codetot.com:22 codetot-app codetot-app-new
```
