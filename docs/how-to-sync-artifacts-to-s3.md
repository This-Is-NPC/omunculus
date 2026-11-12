# How to sync artifacts to S3

**The question:** how do I keep a copy of a conversation's artifacts in an
S3-compatible bucket (AWS S3, MinIO, Cloudflare R2, Backblaze B2), and get
them back?

This page is enough on its own for a project whose `omunculus.toml` loads
([how to start a project](how-to-start-a-project.md)). The keys are listed
in [the TOML](config.md#artifacts-in-a-bucket) and the tools in
[tools](tools.md#artifacts-in-a-bucket).

## Before you start

- A bucket, and an access key that may list, read and write it.
- `[store] attachments` set: artifacts need it
  ([tools](tools.md#artifacts)).
- A way to give the key to the project that keeps it out of the file: an
  environment variable, or a command such as `omapass get -- <account>`
  ([how to log in to a provider](how-to-log-in-to-a-provider.md) shows the
  same `[auth]` forms).
- `<bucket>`, `<endpoint>`, `<region>` and `<prefix>` are placeholders for
  your own values.

## Steps

1. Declare the two halves of the key as `[auth]` providers. Each `key` is
   `$VAR`, `!cmd` or a stored login; none is the secret itself.

   ```toml
   [auth.bucket_id]
   kind = "api_key"
   key = "$BUCKET_ACCESS_KEY_ID"

   [auth.bucket_secret]
   kind = "api_key"
   key = "$BUCKET_SECRET_ACCESS_KEY"
   ```

2. Add the `[settings.s3]` table. Every key is required.

   ```toml
   [settings.s3]
   bucket = "<bucket>"
   endpoint = "<endpoint>"
   region = "<region>"
   prefix = "<prefix>"
   path_style = true
   credentials = { access_key_id = "bucket_id", secret_access_key = "bucket_secret" }
   ```

   `endpoint` is the service's URL without a path. `path_style = true` fits
   MinIO and most self-hosted services; AWS S3, R2 and B2 take `false`.
   `prefix` is the folder everything goes under; `""` is the bucket's root.
   For a local MinIO: `endpoint = "http://localhost:9000"`,
   `region = "us-east-1"`, `path_style = true`.

3. Give an agent the two tools in its ceiling: add `push_artifacts` and
   `pull_artifacts` to its `tools` ([the ceiling](ceiling.md)).

4. Ask that agent to call `push_artifacts`. Expected output the first time
   for a conversation with two versions of one artifact:

   ```text
   pushed 4 objects, 0 already in the bucket
   ```

   Two objects are the contents (`<prefix>/objects/<sha256>`), two are the
   version records
   (`<prefix>/conversations/<conversation>/<name>/<version>.json`). Calling
   it again changes nothing:

   ```text
   pushed 0 objects, 4 already in the bucket
   ```

5. To push after every write, add a hook on the `artifact` event
   (`tools/on-artifact/hook.toml` in a `[tools] paths` folder). The agent
   that writes needs `push_artifacts` in its ceiling.

   ```toml
   name = "on-artifact"
   kind = "hook"
   events = ["artifact"]
   module = "Omunculus.Hooks.Noop"
   chains = ["push_artifacts"]
   then = ["push_artifacts"]
   ```

6. To restore, ask an agent to call `pull_artifacts` in the conversation
   that lacks the versions. It names the source conversation with
   `conversation` when it is another one. Expected output:

   ```text
   restored 2 versions
   ```

   Repeating it restores nothing more (`restored 0 versions`).

## Troubleshooting

| You see | Because |
| --- | --- |
| `no [settings.s3] table in the config` | step 2 is missing |
| `[settings.s3] <key> is missing or not valid` | a key of the table is absent or of the wrong type |
| `the bucket answered 403` | the key may not use the bucket, `region` is not the bucket's, or `path_style` is wrong for the service |
| `the bucket answered 404` | `bucket` or `endpoint` is wrong, or the bucket does not exist |
| `the bucket could not be reached` | `endpoint` does not answer |
| `[settings.s3] credentials name <id>, which [auth] does not hold` | a name in `credentials` is not an `[auth]` provider |
| `left out, out of order: <name> v<n>` | `pull_artifacts` restores versions only in sequence |

## Next

- [Tools](tools.md#artifacts-in-a-bucket): what each tool does and writes.
- [The TOML](config.md#artifacts-in-a-bucket): each key.
