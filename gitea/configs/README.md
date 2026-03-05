# Gitea Configurations

This directory contains custom Gitea configuration files for the CTF environment.

## Usage

Place custom Gitea configuration files here that extend or override the default Helm chart settings.

## Configuration Files

You can add:
- **app.ini**: Custom Gitea application configuration
- **custom templates**: Custom UI templates
- **custom static files**: Custom CSS, JS, images
- **hooks**: Git hooks to apply globally

## Example: Custom app.ini

Create `app.ini` to customize Gitea settings:

```ini
[server]
DOMAIN = localhost
HTTP_PORT = 3000

[security]
INSTALL_LOCK = true

[repository]
ENABLE_PUSH_CREATE_USER = true
DEFAULT_BRANCH = main

[ui]
DEFAULT_THEME = arc-green
```

## Applying Configurations

Mount these configurations in the Gitea deployment using ConfigMaps or by modifying the Helm values.
