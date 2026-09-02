# Discourse Moaclab Reanodize

Stores and manages Moaclab re-anodize service requests submitted by the `moaclab-reanodize-request` theme component.

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

## Notes

The first backend version stores uploaded file names from the theme component. A later version can replace this with Discourse Upload records for case images and payment screenshots.
