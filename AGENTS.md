# Agent Notes

Before handing off changes, run the local shell checks:

```sh
shellcheck download_media.sh list_media.sh media_common.sh
```

Also verify command-line parsing still works by checking help output for any changed script:

```sh
./download_media.sh --help
./list_media.sh --help
```
