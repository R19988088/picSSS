# picSSS

Rust + Flutter desktop image viewer. The UI path is GPU-first through Flutter's
desktop renderer; GTX 1080 is the minimum target GPU.

## Run

```powershell
flutter run -d windows
```

The Windows build calls `cargo build --release` for `rust/picsss_core` and
copies `picsss_core.dll` next to `picsss.exe`.

## Controls

- Mouse wheel: zoom
- Shift + drag up/down: zoom
- Shift + drag left/right: rotate
- Esc once: reset angle
- Esc twice: toggle fit/cover inside the window
- Move pointer to the top-right corner: window controls
- Move pointer to the lower center: sibling thumbnails
- Arrow/Page keys: previous/next
- O: open image, `.sssp`, zip/cbz/cbr/rar

## File Support

Normal image files are displayed directly. `.sssp` files are parsed as JSON,
visible PNG layers are composited into a cached preview, and unsupported
adjustments/effects are kept as metadata instead of being silently faked.

Zip/cbz files are read directly. CBR/RAR support uses an available system
extractor: `7z`, `unrar`, or `tar`.
