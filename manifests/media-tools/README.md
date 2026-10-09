# media-tools

[media-tools](https://github.com/wuguishifu/media-tools) provides static `ffmpeg` and `ffprobe`, and
`yt-dlp`, for other apps, so they don't each bundle their own. On start it copies them into
`/opt/media-tools` on sol (a `hostPath`), then keeps running to update yt-dlp daily, since old
yt-dlp versions stop working with YouTube quickly. Image Updater pins the image's digest, so
publishing a new release (its **Release** workflow) updates ffmpeg too.

## Using the binaries in an app

Mount the directory read-only and point the app at the binary:

```yaml
      containers:
        - name: my-app
          env:
            - name: FFMPEG_PATH
              value: /opt/media-tools/ffmpeg
          volumeMounts:
            - name: media-tools
              mountPath: /opt/media-tools
              readOnly: true
      volumes:
        - name: media-tools
          hostPath:
            path: /opt/media-tools
            # Not DirectoryOrCreate: the pod waits until media-tools has created it.
            type: Directory
```

Mount the whole directory, not single files: a single-file mount keeps pointing at the old file
after an update replaces it. `ffmpeg` and `ffprobe` are fully static, so they run in any image;
`yt-dlp` needs glibc (Debian, Ubuntu, `*-slim`), not Alpine.

Used by: `jankbot-stitcher` (`manifests/jankbot`).

## Checking it

```sh
sudo kubectl -n media-tools logs deploy/media-tools   # "[media-tools] installed to /out:" and versions
ls -la /opt/media-tools                               # on sol
```
