use std::{
    ffi::{CStr, CString},
    fs::{self, File},
    os::raw::c_char,
    path::{Path, PathBuf},
    process::Command,
    time::UNIX_EPOCH,
};

use base64::{Engine as _, engine::general_purpose};
use image::{DynamicImage, GenericImageView, ImageBuffer, Rgba, RgbaImage, imageops::FilterType};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use walkdir::WalkDir;
use zip::ZipArchive;

#[derive(Serialize)]
struct ApiResult<T: Serialize> {
    ok: bool,
    data: Option<T>,
    error: Option<String>,
}

#[derive(Serialize)]
struct PickResult {
    path: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ImageItem {
    id: String,
    title: String,
    kind: String,
    format: String,
    path: Option<String>,
    archive_path: Option<String>,
    entry_name: Option<String>,
    preview_path: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    sssp: Option<SsspInfo>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SsspInfo {
    format_version: Option<i64>,
    canvas_width: Option<u32>,
    canvas_height: Option<u32>,
    layer_count: usize,
    visible_layer_count: usize,
    adjustment_layer_count: usize,
    unsupported_effect_count: usize,
}

struct SsspLayerRender {
    bytes: Vec<u8>,
    opacity: f32,
    blend_mode: String,
    offset_x: i32,
    offset_y: i32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LibraryPayload {
    root: String,
    title: String,
    kind: String,
    selected_index: usize,
    items: Vec<ImageItem>,
    notes: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MaterializedItem {
    path: String,
    preview_path: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    notes: Vec<String>,
}

const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic", "heif", "jxl", "ico",
];

#[unsafe(no_mangle)]
pub extern "C" fn picsss_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn picsss_open_path(path: *const c_char) -> *mut c_char {
    let result = read_c_string(path).and_then(|path| open_path(Path::new(&path)));
    to_c_json(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn picsss_materialize_item(item_json: *const c_char) -> *mut c_char {
    let result = read_c_string(item_json).and_then(|json| materialize_item_json(&json));
    to_c_json(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn picsss_pick_path() -> *mut c_char {
    let file = rfd::FileDialog::new()
        .add_filter(
            "Pictures and comics",
            &[
                "jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic", "heif",
                "jxl", "ico", "sssp", "zip", "cbz", "cbr", "rar",
            ],
        )
        .pick_file();

    let result = file
        .map(|path| PickResult {
            path: path.to_string_lossy().to_string(),
        })
        .ok_or_else(|| "没有选择文件".to_string());
    to_c_json(result)
}

fn read_c_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("收到空路径".to_string());
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str
        .to_str()
        .map(|value| value.to_string())
        .map_err(|err| format!("路径不是有效 UTF-8: {err}"))
}

fn to_c_json<T: Serialize>(result: Result<T, String>) -> *mut c_char {
    let json = match result {
        Ok(data) => serde_json::to_string(&ApiResult {
            ok: true,
            data: Some(data),
            error: None,
        }),
        Err(error) => serde_json::to_string(&ApiResult::<()> {
            ok: false,
            data: None,
            error: Some(error),
        }),
    }
    .unwrap_or_else(|err| {
        format!(
            "{{\"ok\":false,\"data\":null,\"error\":\"序列化失败: {}\"}}",
            escape_json(&err.to_string())
        )
    });
    CString::new(json).unwrap().into_raw()
}

fn escape_json(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn open_path(path: &Path) -> Result<LibraryPayload, String> {
    if !path.exists() {
        return Err(format!("路径不存在: {}", path.display()));
    }

    if path.is_dir() {
        return open_folder(path, None);
    }

    let ext = extension(path);
    if matches!(ext.as_str(), "zip" | "cbz") {
        return open_zip(path);
    }
    if matches!(ext.as_str(), "cbr" | "rar") {
        return open_rar_like(path);
    }

    if ext == "sssp" || is_image_extension(&ext) {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        return open_folder(parent, Some(path));
    }

    Err(format!("不支持的文件类型: {}", path.display()))
}

fn open_folder(folder: &Path, selected: Option<&Path>) -> Result<LibraryPayload, String> {
    let mut items = Vec::new();
    let mut notes = Vec::new();

    let entries = fs::read_dir(folder).map_err(|err| format!("读取文件夹失败: {err}"))?;
    for entry in entries {
        let entry = entry.map_err(|err| format!("读取文件失败: {err}"))?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let ext = extension(&path);
        if ext == "sssp" {
            match sssp_item(&path) {
                Ok(item) => items.push(item),
                Err(err) => notes.push(format!("{}: {}", path.display(), err)),
            }
        } else if is_image_extension(&ext) {
            items.push(file_item(&path, "file"));
        }
    }

    items.sort_by(|a, b| compare_titles(&a.title, &b.title));

    if items.is_empty() {
        return Err(format!("文件夹里没有可显示的图片: {}", folder.display()));
    }

    let selected_index = selected
        .and_then(|target| {
            let target = normalize_path(target);
            items.iter().position(|item| {
                item.path
                    .as_deref()
                    .map(|path| normalize_path(Path::new(path)) == target)
                    .unwrap_or(false)
            })
        })
        .unwrap_or(0);

    Ok(LibraryPayload {
        root: folder.to_string_lossy().to_string(),
        title: folder
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("picSSS")
            .to_string(),
        kind: "folder".to_string(),
        selected_index,
        items,
        notes,
    })
}

fn open_zip(path: &Path) -> Result<LibraryPayload, String> {
    let file = File::open(path).map_err(|err| format!("打开压缩包失败: {err}"))?;
    let mut zip = ZipArchive::new(file).map_err(|err| format!("读取 zip/cbz 失败: {err}"))?;
    let mut items = Vec::new();

    for index in 0..zip.len() {
        let entry = zip
            .by_index(index)
            .map_err(|err| format!("读取压缩包条目失败: {err}"))?;
        if !entry.is_file() {
            continue;
        }

        let name = entry.name().replace('\\', "/");
        let ext = extension(Path::new(&name));
        if is_image_extension(&ext) || ext == "sssp" {
            items.push(ImageItem {
                id: stable_id(&format!("{}::{name}", path.display())),
                title: Path::new(&name)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(&name)
                    .to_string(),
                kind: "archive".to_string(),
                format: ext,
                path: None,
                archive_path: Some(path.to_string_lossy().to_string()),
                entry_name: Some(name),
                preview_path: None,
                width: None,
                height: None,
                sssp: None,
            });
        }
    }

    items.sort_by(|a, b| compare_titles(&a.title, &b.title));

    if items.is_empty() {
        return Err(format!("压缩包里没有可显示的图片: {}", path.display()));
    }

    Ok(LibraryPayload {
        root: path.to_string_lossy().to_string(),
        title: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("zip/cbz")
            .to_string(),
        kind: "archive".to_string(),
        selected_index: 0,
        items,
        notes: Vec::new(),
    })
}

fn open_rar_like(path: &Path) -> Result<LibraryPayload, String> {
    let cache_dir = rar_cache_dir(path)?;
    fs::create_dir_all(&cache_dir).map_err(|err| format!("创建 cbr 缓存失败: {err}"))?;

    if is_dir_empty(&cache_dir)? {
        extract_rar_like(path, &cache_dir)?;
    }

    let mut items = Vec::new();
    for entry in WalkDir::new(&cache_dir).into_iter().filter_map(Result::ok) {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let ext = extension(path);
        if ext == "sssp" {
            if let Ok(item) = sssp_item(path) {
                items.push(item);
            }
        } else if is_image_extension(&ext) {
            items.push(file_item(path, "file"));
        }
    }

    items.sort_by(|a, b| compare_titles(&a.title, &b.title));

    if items.is_empty() {
        return Err(format!("cbr/rar 里没有可显示的图片: {}", path.display()));
    }

    Ok(LibraryPayload {
        root: path.to_string_lossy().to_string(),
        title: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("cbr")
            .to_string(),
        kind: "archive".to_string(),
        selected_index: 0,
        items,
        notes: vec![
            "CBR/RAR 已解包到系统临时缓存；如果系统没有 7z/unrar/tar，将无法读取。".to_string(),
        ],
    })
}

fn materialize_item_json(json: &str) -> Result<MaterializedItem, String> {
    let value: Value =
        serde_json::from_str(json).map_err(|err| format!("条目 JSON 无效: {err}"))?;
    let kind = value
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| "条目缺少 kind".to_string())?;

    match kind {
        "file" | "sssp" => {
            let path = value
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| "条目缺少 path".to_string())?;
            Ok(MaterializedItem {
                path: path.to_string(),
                preview_path: value
                    .get("previewPath")
                    .and_then(Value::as_str)
                    .map(ToString::to_string),
                width: value.get("width").and_then(Value::as_u64).map(|v| v as u32),
                height: value
                    .get("height")
                    .and_then(Value::as_u64)
                    .map(|v| v as u32),
                notes: Vec::new(),
            })
        }
        "archive" => materialize_archive_item(&value),
        other => Err(format!("未知条目类型: {other}")),
    }
}

fn materialize_archive_item(value: &Value) -> Result<MaterializedItem, String> {
    let archive_path = value
        .get("archivePath")
        .and_then(Value::as_str)
        .ok_or_else(|| "压缩包条目缺少 archivePath".to_string())?;
    let entry_name = value
        .get("entryName")
        .and_then(Value::as_str)
        .ok_or_else(|| "压缩包条目缺少 entryName".to_string())?;

    let archive_path = Path::new(archive_path);
    let ext = extension(Path::new(entry_name));
    let cache_path = cache_dir()
        .join("zip")
        .join(stable_id(&archive_fingerprint(archive_path)?))
        .join(safe_entry_cache_name(entry_name, &ext));

    if !cache_path.exists() {
        if let Some(parent) = cache_path.parent() {
            fs::create_dir_all(parent).map_err(|err| format!("创建压缩包缓存失败: {err}"))?;
        }
        let mut zip = ZipArchive::new(
            File::open(archive_path).map_err(|err| format!("打开压缩包失败: {err}"))?,
        )
        .map_err(|err| format!("读取压缩包失败: {err}"))?;
        let mut entry = zip
            .by_name(entry_name)
            .map_err(|err| format!("读取压缩包图片失败: {err}"))?;
        let mut output =
            File::create(&cache_path).map_err(|err| format!("创建缓存文件失败: {err}"))?;
        std::io::copy(&mut entry, &mut output).map_err(|err| format!("解压图片失败: {err}"))?;
    }

    if ext == "sssp" {
        let item = sssp_item(&cache_path)?;
        return Ok(MaterializedItem {
            path: item
                .preview_path
                .clone()
                .unwrap_or_else(|| cache_path.to_string_lossy().to_string()),
            preview_path: item.preview_path,
            width: item.width,
            height: item.height,
            notes: vec!["已从 zip/cbz 中读取 sssp 预览。".to_string()],
        });
    }

    let (width, height) = image_dimensions(&cache_path);
    Ok(MaterializedItem {
        path: cache_path.to_string_lossy().to_string(),
        preview_path: None,
        width,
        height,
        notes: Vec::new(),
    })
}

fn sssp_item(path: &Path) -> Result<ImageItem, String> {
    let text = fs::read_to_string(path).map_err(|err| format!("读取 sssp 失败: {err}"))?;
    let value: Value =
        serde_json::from_str(&text).map_err(|err| format!("解析 sssp 失败: {err}"))?;
    let info = sssp_info(&value);
    let preview_path = render_sssp_preview(path, &value)?;

    Ok(ImageItem {
        id: stable_id(&path_fingerprint(path)),
        title: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("sssp")
            .to_string(),
        kind: "sssp".to_string(),
        format: "sssp".to_string(),
        path: Some(preview_path.to_string_lossy().to_string()),
        archive_path: None,
        entry_name: None,
        preview_path: Some(preview_path.to_string_lossy().to_string()),
        width: info.canvas_width,
        height: info.canvas_height,
        sssp: Some(info),
    })
}

fn sssp_info(value: &Value) -> SsspInfo {
    let layers = value
        .get("layers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let visible_layer_count = layers
        .iter()
        .filter(|layer| {
            layer
                .get("visible")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        })
        .count();
    let adjustment_layer_count = layers
        .iter()
        .filter(|layer| layer.get("adjustment").is_some())
        .count();
    let unsupported_effect_count = adjustment_layer_count
        + usize::from(value.get("canvasTexture").is_some())
        + layers
            .iter()
            .filter(|layer| {
                layer
                    .get("blendMode")
                    .and_then(Value::as_str)
                    .map(|mode| !matches!(mode, "normal" | "sourceOver"))
                    .unwrap_or(false)
            })
            .count();

    SsspInfo {
        format_version: value.get("formatVersion").and_then(Value::as_i64),
        canvas_width: sssp_canvas_size(value).map(|(width, _)| width),
        canvas_height: sssp_canvas_size(value).map(|(_, height)| height),
        layer_count: layers.len(),
        visible_layer_count,
        adjustment_layer_count,
        unsupported_effect_count,
    }
}

fn render_sssp_preview(path: &Path, value: &Value) -> Result<PathBuf, String> {
    let cache_path = cache_dir()
        .join("sssp")
        .join(format!("{}-v2.png", stable_id(&path_fingerprint(path))));
    if cache_path.exists() {
        return Ok(cache_path);
    }

    if let Some(parent) = cache_path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("创建 sssp 缓存失败: {err}"))?;
    }

    let canvas_size = sssp_canvas_size(value);
    let mut layers = sssp_image_layers(value);

    if let Some(bytes) = sssp_embedded_preview(value, !layers.is_empty())? {
        let image = image::load_from_memory(&bytes)
            .map_err(|err| format!("解码 sssp 合成预览失败: {err}"))?;
        save_sssp_canvas_image(image, canvas_size, &cache_path)?;
        return Ok(cache_path);
    }

    if layers.is_empty() {
        return Err("sssp 中没有可渲染的 imageData/imageDataBase64 图层".to_string());
    }

    if layers.len() == 1 {
        let layer = layers.remove(0);
        if canvas_size.is_none()
            && layer.offset_x == 0
            && layer.offset_y == 0
            && layer.opacity >= 0.999
        {
            fs::write(&cache_path, layer.bytes)
                .map_err(|err| format!("写入 sssp 预览失败: {err}"))?;
            return Ok(cache_path);
        }
        let image = image::load_from_memory(&layer.bytes)
            .map_err(|err| format!("解码 sssp 图层失败: {err}"))?
            .to_rgba8();
        let (canvas_width, canvas_height) = canvas_size.unwrap_or_else(|| image.dimensions());
        let mut canvas = ImageBuffer::from_pixel(canvas_width, canvas_height, Rgba([0, 0, 0, 0]));
        blend_layer(&mut canvas, &image, &layer);
        DynamicImage::ImageRgba8(canvas)
            .save(&cache_path)
            .map_err(|err| format!("保存 sssp 预览失败: {err}"))?;
        return Ok(cache_path);
    }

    let mut canvas: Option<RgbaImage> =
        canvas_size.map(|(w, h)| ImageBuffer::from_pixel(w, h, Rgba([0, 0, 0, 0])));

    for layer in layers {
        let image = image::load_from_memory(&layer.bytes)
            .map_err(|err| format!("解码 sssp 图层失败: {err}"))?
            .to_rgba8();
        if canvas.is_none() {
            let (w, h) = image.dimensions();
            canvas = Some(ImageBuffer::from_pixel(w, h, Rgba([0, 0, 0, 0])));
        }
        if let Some(canvas) = canvas.as_mut() {
            blend_layer(canvas, &image, &layer);
        }
    }

    let Some(canvas) = canvas else {
        return Err("sssp 预览渲染失败".to_string());
    };

    DynamicImage::ImageRgba8(canvas)
        .save(&cache_path)
        .map_err(|err| format!("保存 sssp 预览失败: {err}"))?;

    Ok(cache_path)
}

fn sssp_canvas_size(value: &Value) -> Option<(u32, u32)> {
    let width = value
        .get("canvasWidth")
        .or_else(|| value.get("width"))
        .or_else(|| value.pointer("/canvas/width"))
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .map(|value| value as u32)?;
    let height = value
        .get("canvasHeight")
        .or_else(|| value.get("height"))
        .or_else(|| value.pointer("/canvas/height"))
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .map(|value| value as u32)?;
    Some((width, height))
}

fn save_sssp_canvas_image(
    image: DynamicImage,
    canvas_size: Option<(u32, u32)>,
    cache_path: &Path,
) -> Result<(), String> {
    let Some((canvas_width, canvas_height)) = canvas_size else {
        image
            .save(cache_path)
            .map_err(|err| format!("保存 sssp 预览失败: {err}"))?;
        return Ok(());
    };

    if image.dimensions() == (canvas_width, canvas_height) {
        image
            .save(cache_path)
            .map_err(|err| format!("保存 sssp 预览失败: {err}"))?;
        return Ok(());
    }

    let resized = image.resize_exact(canvas_width, canvas_height, FilterType::Lanczos3);
    resized
        .save(cache_path)
        .map_err(|err| format!("保存 sssp 预览失败: {err}"))
}

fn sssp_embedded_preview(value: &Value, has_layers: bool) -> Result<Option<Vec<u8>>, String> {
    let keys: &[&str] = if has_layers {
        &["flattenedImage", "previewImage", "preview"]
    } else {
        &["flattenedImage", "previewImage", "preview", "thumbnail"]
    };
    for key in keys {
        if let Some(data) = value.get(key).and_then(Value::as_str) {
            return decode_base64_image(data).map(Some);
        }
    }
    Ok(None)
}

fn sssp_image_layers(value: &Value) -> Vec<SsspLayerRender> {
    let layers = value
        .get("layers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let order = value
        .get("layerOrder")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToString::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let mut ordered_layers = Vec::new();
    if order.is_empty() {
        ordered_layers = layers;
    } else {
        for id in order {
            if let Some(layer) = layers
                .iter()
                .find(|layer| layer.get("id").and_then(Value::as_str) == Some(id.as_str()))
            {
                ordered_layers.push(layer.clone());
            }
        }
    }

    ordered_layers
        .into_iter()
        .filter(|layer| {
            layer
                .get("visible")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        })
        .filter_map(|layer| {
            if layer
                .get("type")
                .and_then(Value::as_str)
                .map(|kind| kind == "adjustment" || kind == "group")
                .unwrap_or(false)
            {
                return None;
            }
            let data = layer
                .get("imageData")
                .or_else(|| layer.get("imageDataBase64"))
                .and_then(Value::as_str)?;
            let opacity = layer
                .get("opacity")
                .and_then(Value::as_f64)
                .map(|value| value.clamp(0.0, 1.0) as f32)
                .unwrap_or(1.0);
            let blend_mode = normalize_sssp_blend_mode(
                layer
                    .get("blendMode")
                    .and_then(Value::as_str)
                    .unwrap_or("normal"),
            );
            let offset_x = layer
                .get("offsetX")
                .or_else(|| layer.get("x"))
                .and_then(Value::as_i64)
                .unwrap_or(0) as i32;
            let offset_y = layer
                .get("offsetY")
                .or_else(|| layer.get("y"))
                .and_then(Value::as_i64)
                .unwrap_or(0) as i32;
            decode_base64_image(data).ok().map(|bytes| SsspLayerRender {
                bytes,
                opacity,
                blend_mode,
                offset_x,
                offset_y,
            })
        })
        .collect()
}

fn decode_base64_image(data: &str) -> Result<Vec<u8>, String> {
    let payload = data
        .split_once(',')
        .map(|(_, payload)| payload)
        .unwrap_or(data)
        .trim();
    general_purpose::STANDARD
        .decode(payload)
        .map_err(|err| format!("解码 base64 图片失败: {err}"))
}

fn normalize_sssp_blend_mode(raw: &str) -> String {
    let value = raw.trim().to_ascii_lowercase();
    let canonical = value.trim_start_matches("svg:").replace(['_', ' '], "-");
    let compact = canonical.replace('-', "");
    match canonical.as_str() {
        "source-over" | "src-over" | "normal" => "normal",
        "color-burn" | "colorburn" => "color-burn",
        "linear-burn" | "linearburn" => "linear-burn",
        "watercolor-burn" | "watercolorburn" => "watercolor-burn",
        "color-dodge" | "colordodge" => "color-dodge",
        "linear-dodge" | "lineardodge" => "linear-dodge",
        "overlay-sp" | "overlaysp" => "overlay-sp",
        "soft-light" | "softlight" => "soft-light",
        "hard-light" | "hardlight" => "hard-light",
        "vivid-light" | "vividlight" => "vivid-light",
        "linear-light" | "linearlight" => "linear-light",
        "pin-light" | "pinlight" => "pin-light",
        "hard-mix" | "hardmix" => "hard-mix",
        "multiply" | "screen" | "overlay" | "darken" | "lighten" | "difference" | "exclusion"
        | "subtract" | "divide" | "hue" | "saturation" | "color" | "luminosity" => {
            canonical.as_str()
        }
        _ => match compact.as_str() {
            "colorburn" => "color-burn",
            "linearburn" => "linear-burn",
            "watercolorburn" => "watercolor-burn",
            "colordodge" => "color-dodge",
            "lineardodge" => "linear-dodge",
            "overlaysp" => "overlay-sp",
            "softlight" => "soft-light",
            "hardlight" => "hard-light",
            "vividlight" => "vivid-light",
            "linearlight" => "linear-light",
            "pinlight" => "pin-light",
            "hardmix" => "hard-mix",
            _ => "normal",
        },
    }
    .to_string()
}

fn blend_layer(canvas: &mut RgbaImage, layer_image: &RgbaImage, layer: &SsspLayerRender) {
    let start_x = layer.offset_x.max(0) as u32;
    let start_y = layer.offset_y.max(0) as u32;
    let src_start_x = (-layer.offset_x).max(0) as u32;
    let src_start_y = (-layer.offset_y).max(0) as u32;
    if start_x >= canvas.width()
        || start_y >= canvas.height()
        || src_start_x >= layer_image.width()
        || src_start_y >= layer_image.height()
    {
        return;
    }

    let width = (canvas.width() - start_x).min(layer_image.width() - src_start_x);
    let height = (canvas.height() - start_y).min(layer_image.height() - src_start_y);

    for y in 0..height {
        for x in 0..width {
            let src = layer_image.get_pixel(src_start_x + x, src_start_y + y).0;
            let dst = canvas.get_pixel(start_x + x, start_y + y).0;
            let src_a = (src[3] as f32 / 255.0) * layer.opacity;
            if src_a <= 0.0 {
                continue;
            }
            let dst_a = dst[3] as f32 / 255.0;
            let out_a = src_a + dst_a * (1.0 - src_a);
            if out_a <= 0.0 {
                canvas.put_pixel(start_x + x, start_y + y, Rgba([0, 0, 0, 0]));
                continue;
            }
            let mut out = [0u8; 4];
            for channel in 0..3 {
                let src_c = src[channel] as f32 / 255.0;
                let dst_c = dst[channel] as f32 / 255.0;
                let blended = blend_channel(src_c, dst_c, &layer.blend_mode);
                let out_c = (blended * src_a + dst_c * dst_a * (1.0 - src_a)) / out_a;
                out[channel] = (out_c * 255.0).round().clamp(0.0, 255.0) as u8;
            }
            out[3] = (out_a * 255.0).round().clamp(0.0, 255.0) as u8;
            canvas.put_pixel(start_x + x, start_y + y, Rgba(out));
        }
    }
}

fn blend_channel(src: f32, dst: f32, mode: &str) -> f32 {
    match mode {
        "multiply" => src * dst,
        "screen" => 1.0 - (1.0 - src) * (1.0 - dst),
        "overlay" | "overlay-sp" => {
            if dst <= 0.5 {
                2.0 * src * dst
            } else {
                1.0 - 2.0 * (1.0 - src) * (1.0 - dst)
            }
        }
        "darken" => src.min(dst),
        "lighten" => src.max(dst),
        "color-burn" | "linear-burn" | "watercolor-burn" => {
            if src <= 0.0 {
                0.0
            } else {
                1.0 - ((1.0 - dst) / src).min(1.0)
            }
        }
        "color-dodge" | "linear-dodge" => {
            if src >= 1.0 {
                1.0
            } else {
                (dst / (1.0 - src)).min(1.0)
            }
        }
        "soft-light" => {
            if src <= 0.5 {
                dst - (1.0 - 2.0 * src) * dst * (1.0 - dst)
            } else {
                let g = if dst <= 0.25 {
                    ((16.0 * dst - 12.0) * dst + 4.0) * dst
                } else {
                    dst.sqrt()
                };
                dst + (2.0 * src - 1.0) * (g - dst)
            }
        }
        "hard-light" => {
            if src <= 0.5 {
                2.0 * src * dst
            } else {
                1.0 - 2.0 * (1.0 - src) * (1.0 - dst)
            }
        }
        "difference" => (dst - src).abs(),
        "exclusion" => dst + src - 2.0 * dst * src,
        "subtract" => (dst - src).max(0.0),
        "divide" => {
            if src <= 0.0 {
                1.0
            } else {
                (dst / src).min(1.0)
            }
        }
        _ => src,
    }
    .clamp(0.0, 1.0)
}

fn file_item(path: &Path, kind: &str) -> ImageItem {
    let (width, height) = image_dimensions(path);
    ImageItem {
        id: stable_id(&path_fingerprint(path)),
        title: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("image")
            .to_string(),
        kind: kind.to_string(),
        format: extension(path),
        path: Some(path.to_string_lossy().to_string()),
        archive_path: None,
        entry_name: None,
        preview_path: None,
        width,
        height,
        sssp: None,
    }
}

fn image_dimensions(path: &Path) -> (Option<u32>, Option<u32>) {
    image::image_dimensions(path)
        .map(|(width, height)| (Some(width), Some(height)))
        .unwrap_or((None, None))
}

fn is_image_extension(ext: &str) -> bool {
    IMAGE_EXTENSIONS.contains(&ext)
}

fn extension(path: &Path) -> String {
    path.extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn compare_titles(a: &str, b: &str) -> std::cmp::Ordering {
    a.to_ascii_lowercase().cmp(&b.to_ascii_lowercase())
}

fn normalize_path(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .to_ascii_lowercase()
}

fn path_fingerprint(path: &Path) -> String {
    let modified = path
        .metadata()
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or_default();
    format!("{}:{modified}", path.display())
}

fn archive_fingerprint(path: &Path) -> Result<String, String> {
    let metadata = path
        .metadata()
        .map_err(|err| format!("读取压缩包信息失败: {err}"))?;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or_default();
    Ok(format!("{}:{}:{modified}", path.display(), metadata.len()))
}

fn stable_id(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    let hash = hasher.finalize();
    hash.iter()
        .take(12)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn cache_dir() -> PathBuf {
    std::env::temp_dir().join("picsss_cache")
}

fn rar_cache_dir(path: &Path) -> Result<PathBuf, String> {
    Ok(cache_dir()
        .join("rar")
        .join(stable_id(&archive_fingerprint(path)?)))
}

fn is_dir_empty(path: &Path) -> Result<bool, String> {
    Ok(fs::read_dir(path)
        .map_err(|err| format!("读取缓存目录失败: {err}"))?
        .next()
        .is_none())
}

fn extract_rar_like(path: &Path, target_dir: &Path) -> Result<(), String> {
    if command_exists("7z") {
        let status = Command::new("7z")
            .arg("x")
            .arg("-y")
            .arg(format!("-o{}", target_dir.display()))
            .arg(path)
            .status()
            .map_err(|err| format!("运行 7z 失败: {err}"))?;
        if status.success() {
            return Ok(());
        }
    }

    if command_exists("unrar") {
        let status = Command::new("unrar")
            .arg("x")
            .arg("-y")
            .arg(path)
            .arg(target_dir)
            .status()
            .map_err(|err| format!("运行 unrar 失败: {err}"))?;
        if status.success() {
            return Ok(());
        }
    }

    if command_exists("tar") {
        let status = Command::new("tar")
            .arg("-xf")
            .arg(path)
            .arg("-C")
            .arg(target_dir)
            .status()
            .map_err(|err| format!("运行 tar 失败: {err}"))?;
        if status.success() {
            return Ok(());
        }
    }

    Err("CBR/RAR 需要系统可用的 7z、unrar 或 tar；当前没有可用解包器。".to_string())
}

fn command_exists(name: &str) -> bool {
    let checker = if cfg!(windows) { "where" } else { "which" };
    Command::new(checker)
        .arg(name)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn safe_entry_cache_name(entry_name: &str, ext: &str) -> String {
    let mut name = stable_id(entry_name);
    if !ext.is_empty() {
        name.push('.');
        name.push_str(ext);
    }
    name
}
