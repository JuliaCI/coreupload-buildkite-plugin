# coreupload-buildkite-plugin

This plugin provides a convenient way to upload linux corefiles to buildkite artifact storage, compressing them if `zstd` is available.

## Example

```yaml
steps:
  - label: ":julia: Run segfaulting tests"
    plugins:
      - JuliaCI/julia#v1: ~
      - JuliaCI/coreupload#v2:
          core_pattern: "*.core"
          compressor: "zstd"
          create_bundle: "true"
          gdb_commands:
            - "thread apply all bt"
            - "info file"
    commands: |
      julia naughty_script.jl
```

Core files (and their compressed bundles) are deleted once the plugin is done with them, and a core is not compressed when that would leave less than 5 GiB of free disk space.

## Options

* `core_pattern`: A glob expression that should match every core file you want to process.
* `compressor`: A compressor to be used to reduce corefile size before upload.  Currently only supports `none` and `zstd`.  Note that `zstd` must be available on the path in order to be used.
* `gdb_commands`: An array of commands that will be invoked by `gdb` before upload, for easy visual inspection of useful debugging information without even downloading the corefiles.  Note that `gdb` and `file` must be available on the path in order to be used.
* `disabled`: A parameter that, if provided and non-empty, disables the plugin entirely.
* `create_bundle`: If `true`, collects all shared libraries into a tarball before uploading.
* `max_cores`: Run the debugger commands on at most this many cores, oldest (by modification time) first.  Default: `10`.
* `max_uploads`: Compress and upload at most this many cores, oldest (by modification time) first, one at a time.  Default: `1`.  A test that crashes repeatedly produces many cores of tens of GB with the same cause; the debugger output covers the others.  A host can lower this limit by setting `COREUPLOAD_MAX_UPLOADS` in its environment (e.g. `0` on a site with a slow uplink).
* `upload_timeout`: Give up on uploading a core after this many seconds.  Default: `900`.
* `debug_plugin`: If `true`, generates large amounts of debugging output during hook execution.
