# coreupload-buildkite-plugin

This plugin provides a convenient way to upload linux corefiles to buildkite artifact storage, compressing them if `zstd` is available.

## Example

```yaml
steps:
  - label: ":julia: Run segfaulting tests"
    plugins:
      - JuliaCI/julia#v1: ~
      - staticfloat/coreupload:
          core_pattern: "*.core"
          compressor: "zstd"
          gdb_commands:
            - "thread apply all bt"
            - "info file"
    commands: |
      julia naughty_script.jl
```

## Options

* `core_pattern`: A glob expression that should match every core file you want to process.
* `compressor`: A compressor to be used to reduce corefile size before upload.  Currently only supports `none` and `zstd`.  Note that `zstd` must be available on the path in order to be used.
* `gdb_commands:` An array of commands that will be invoked by `gdb` before upload, for easy visual inspection of useful debugging information without even downloading the corefiles.  Note that `gdb` and `file` must be available on the path in order to be used.
