# Discourse Moaclab Reanodize

Stores and manages Moaclab re-anodize service requests submitted by the `moaclab-reanodize-request` theme component.

This safety-first version stores records in Discourse `PluginStore`, so installation does not run a custom database migration.

## Install

Add the plugin to the Discourse container and rebuild:

```ruby
git clone https://github.com/mohist-club/discourse-moaclab-reanodize.git
```

## Settings

- `moaclab_reanodize_enabled`: enables the plugin.
- `moaclab_reanodize_manager_group_name`: group allowed to view and manage requests. Admins and moderators are always allowed.

Default manager group:

```text
reanodize_managers
```

## Frontend API

Submit a request:

```http
POST /moaclab/reanodize/requests
```

Current user's requests:

```http
GET /moaclab/reanodize/my
```

## Admin

Open:

```text
/moaclab/reanodize/admin
```

The admin page supports:

- Request list
- Status filter
- Search by request id, kit name, QQ, or payment order number
- Status updates
- Admin note updates
- Clickable image previews when the submitted file value is a Discourse upload URL

## Notes

The backend stores file references sent by the theme component. Current theme versions upload images through Discourse first and submit the returned upload URLs, so the admin page can render thumbnails and clickable image links. Older records that only contain local file names are still shown as text.

For larger-scale operation, migrate the `PluginStore` records to a dedicated database table after the production install has been verified.
