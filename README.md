# video-swift-backend

A description of this package.

# Exporting static data from the old database

- Episodes. In psql, do the following:

```
\t on
\pset format unaligned
SELECT json_agg(t) FROM (
    SELECT e.id, number, title, release_at, created_at, updated_at, season, media_duration, media_src, subscription_only, name, synopsis, media_version, released, poster_uid, sample_src, sample_duration, sample_version, video_id, mailchimp_campaign_id, 
    (SELECT array(
       SELECT collection_id FROM collection_episodes where episode_id = e.id ORDER BY "primary" ASC
       )
    as collections),
    (
      SELECT json_agg(resource) FROM (
        SELECT r.title as title, r.subtitle as subtitle, r.url as url 
        FROM episode_resources r WHERE r.episode_id = e.id
      ) resource
    ) resources,
    (SELECT array(
       SELECT collaborator_id FROM collaborators_episodes where episode_id = e.id
       )
    as collaborators)
    FROM episodes e
) 
t 
\g data/episodes.json
```

To export the collaborators as well, do the following:

```swift
SELECT json_agg(t) FROM (
  SELECT id, name, url, role FROM collaborators ORDER BY created_at ASC
) h 
\g data/collaborators.json
```

Exporting collections:

```swift
SELECT json_agg(t) FROM (
    SELECT id, title, description, public, position, artwork_uid, new, slug, use_as_title_prefix FROM collections ORDER by position DESC
) t \g data/collections.json
```

# Postgres

```
initdb -D .postgres
chmod 700 .postgres
pg_ctl -D .postgres start
```


# Recurly

In the Rails app, I think it works like this:

* When the user signs up, the credit card info never goes to our server, but straight to Recurly. Recurly then sends us a token (in Javascript), which we send back to the server.

* We use this token on the server to create a subscription, and directly create an account as well (in a single request)
