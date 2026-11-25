-- src/theme.lua
-- Reaper ProChannel (ReaPCh) — Studio Dark 视觉体系与 REAPER 宿主主题配色自适应层
-- 职责：
--   1. 提供默认 Studio Dark 低饱和中性深色配色栈、圆角/紧凑间距常量，以及上下双区（0 号位 Channel Strip / 常规 FX 槽）差异化视觉语义色；
--   2. 提供“跟随 REAPER 宿主主题配色”支持（读取 reaper.GetThemeColor 并通过 ColorFromNative 转换为 ReaImGui 0xRRGGBBAA 格式），
--      自动识别明亮白/浅灰底浅色皮肤与深色皮肤（含第三方位图皮肤占位黑容错），通过 HSL 色相保持算法自然承接宿主彩色点缀（如粉红等），
--      并内置基于 WCAG 2.1 相对亮度（Relative Luminance）与对比度（Contrast Ratio）的安全兜底；
--   3. 所有颜色转换、HSL 与对比度兜底函数均为零 ImGui 依赖的纯函数，可脱离宿主在 tests/run.lua 中独立验证。

local theme = {}

theme.DEFAULT_WINDOW_WIDTH = 310
theme.DEFAULT_WINDOW_HEIGHT = 640
theme.MIN_CONTRAST_RATIO = 4.5
theme.LIGHT_LUMINANCE_THRESHOLD = 0.22

theme._active_palette = nil
theme._studio_dark_cache = nil
theme._host_cache_sig = nil
theme._host_cache_palette = nil

local function clamp_byte(v)
  local n = tonumber(v) or 0
  n = math.floor(n + 0.5)
  if n < 0 then
    return 0
  elseif n > 255 then
    return 255
  end
  return n
end

local function clamp01(v)
  local n = tonumber(v) or 0
  if n < 0.0 then
    return 0.0
  elseif n > 1.0 then
    return 1.0
  end
  return n
end

local function enum_val(v)
  if type(v) == "function" then
    return v()
  end
  return v
end

--------------------------------------------------------------------------------
-- 1. 纯 Lua 颜色转换、HSL、相对亮度与对比度安全兜底算法（可脱离 ImGui 独立单测）
--------------------------------------------------------------------------------

--- 将 R, G, B, A (0..255) 打包为 ReaImGui 标准的 0xRRGGBBAA 无符号 32 位整数
function theme.rgba(r, g, b, a)
  local br = clamp_byte(r)
  local bg = clamp_byte(g)
  local bb = clamp_byte(b)
  local ba = (a == nil) and 255 or clamp_byte(a)
  return ((br & 0xFF) << 24)
    | ((bg & 0xFF) << 16)
    | ((bb & 0xFF) << 8)
    | (ba & 0xFF)
end

--- 从 0xRRGGBBAA 无符号 32 位整数解包出 r, g, b, a (0..255)
function theme.unpack_rgba(rgba_int)
  local n = tonumber(rgba_int) or 0
  n = math.floor(n) & 0xFFFFFFFF
  local r = (n >> 24) & 0xFF
  local g = (n >> 16) & 0xFF
  local b = (n >> 8) & 0xFF
  local a = n & 0xFF
  return r, g, b, a
end

--- 替换 0xRRGGBBAA 颜色的 Alpha 通道 (0..255)
function theme.with_alpha(rgba_int, a)
  local r, g, b = theme.unpack_rgba(rgba_int)
  return theme.rgba(r, g, b, a)
end

--- 在两个 0xRRGGBBAA 颜色之间按比例 t (0.0..1.0) 线性混合
function theme.blend_rgba(rgba_a, rgba_b, t)
  local k = clamp01(t)
  local r1, g1, b1, a1 = theme.unpack_rgba(rgba_a)
  local r2, g2, b2, a2 = theme.unpack_rgba(rgba_b)
  return theme.rgba(
    r1 + (r2 - r1) * k,
    g1 + (g2 - g1) * k,
    b1 + (b2 - b1) * k,
    a1 + (a2 - a1) * k
  )
end

--- 将 RGB (0..255) 转换为 HSL：h (0..360), s (0..1), l (0..1)
function theme.rgb_to_hsl(r, g, b)
  local rn = clamp_byte(r) / 255.0
  local gn = clamp_byte(g) / 255.0
  local bn = clamp_byte(b) / 255.0
  local max_c = math.max(rn, gn, bn)
  local min_c = math.min(rn, gn, bn)
  local l = (max_c + min_c) * 0.5
  local d = max_c - min_c

  if d < 1e-6 then
    return 0.0, 0.0, l
  end

  local s = (l > 0.5) and (d / (2.0 - max_c - min_c)) or (d / (max_c + min_c))
  local h
  if max_c == rn then
    h = ((gn - bn) / d) + ((gn < bn) and 6.0 or 0.0)
  elseif max_c == gn then
    h = ((bn - rn) / d) + 2.0
  else
    h = ((rn - gn) / d) + 4.0
  end
  h = (h * 60.0) % 360.0
  return h, clamp01(s), clamp01(l)
end

local function hue_to_rgb(p, q, t)
  local tt = t
  if tt < 0.0 then
    tt = tt + 1.0
  elseif tt > 1.0 then
    tt = tt - 1.0
  end
  if tt < 1.0 / 6.0 then
    return p + (q - p) * 6.0 * tt
  elseif tt < 0.5 then
    return q
  elseif tt < 2.0 / 3.0 then
    return p + (q - p) * (2.0 / 3.0 - tt) * 6.0
  end
  return p
end

--- 将 HSL (h: 0..360, s: 0..1, l: 0..1) 转换为 RGB (0..255)
function theme.hsl_to_rgb(h, s, l)
  local hn = ((tonumber(h) or 0.0) % 360.0) / 360.0
  local sn = clamp01(s)
  local ln = clamp01(l)

  if sn < 1e-6 then
    local v = clamp_byte(ln * 255.0)
    return v, v, v
  end

  local q = (ln < 0.5) and (ln * (1.0 + sn)) or (ln + sn - ln * sn)
  local p = 2.0 * ln - q
  local r = hue_to_rgb(p, q, hn + 1.0 / 3.0)
  local g = hue_to_rgb(p, q, hn)
  local b = hue_to_rgb(p, q, hn - 1.0 / 3.0)
  return clamp_byte(r * 255.0), clamp_byte(g * 255.0), clamp_byte(b * 255.0)
end

--- 将 HSL 打包为 0xRRGGBBAA
function theme.hsla(h, s, l, a)
  local r, g, b = theme.hsl_to_rgb(h, s, l)
  return theme.rgba(r, g, b, (a == nil) and 255 or a)
end

--- 将 REAPER GetThemeColor 返回的原生颜色值转换为 ReaImGui 0xRRGGBBAA 整数
--- @param native_color number|nil REAPER 原生颜色值（负数如 -1 表示未配置或无效）
--- @param a number|nil Alpha 通道 (0..255)，默认 255
--- @param reaper_api table|nil 可选注入的 reaper API 表（优先使用 ColorFromNative 解包）
--- @return number|nil rgba_int 转换后的 0xRRGGBBAA，无效输入返回 nil
function theme.native_to_rgba(native_color, a, reaper_api)
  if type(native_color) ~= "number" or native_color ~= native_color or native_color < 0 then
    return nil
  end
  local raw = math.floor(native_color) & 0xFFFFFF
  local r_api = reaper_api or _G.reaper
  local r, g, b
  if r_api and type(r_api.ColorFromNative) == "function" then
    local ok, cr, cg, cb = pcall(r_api.ColorFromNative, raw)
    if ok and type(cr) == "number" and type(cg) == "number" and type(cb) == "number" then
      r, g, b = cr, cg, cb
    end
  end
  if not r then
    r = raw & 0xFF
    g = (raw >> 8) & 0xFF
    b = (raw >> 16) & 0xFF
  end
  return theme.rgba(r, g, b, (a == nil) and 255 or a)
end

local function srgb_channel_to_linear(c_255)
  local c = clamp_byte(c_255) / 255.0
  if c <= 0.04045 then
    return c / 12.92
  end
  return ((c + 0.055) / 1.055) ^ 2.4
end

--- 计算 WCAG 2.1 相对亮度 (Relative Luminance, 0.0 .. 1.0)
--- 支持传入单个 0xRRGGBBAA 整数，或分别传入 (r, g, b)
function theme.relative_luminance(r_or_rgba, g, b)
  local r = r_or_rgba
  if g == nil and b == nil then
    r, g, b = theme.unpack_rgba(r_or_rgba)
  end
  local rl = srgb_channel_to_linear(r)
  local gl = srgb_channel_to_linear(g)
  local bl = srgb_channel_to_linear(b)
  return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
end

--- 计算两个 0xRRGGBBAA 颜色之间的 WCAG 2.1 对比度 (1.0 .. 21.0)
function theme.contrast_ratio(rgba1, rgba2)
  local l1 = theme.relative_luminance(rgba1)
  local l2 = theme.relative_luminance(rgba2)
  local lighter = math.max(l1, l2)
  local darker = math.min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
end

--- 判断给定 0xRRGGBBAA 颜色是否属于浅色背景
function theme.is_light_color(rgba_int)
  return theme.relative_luminance(rgba_int) > theme.LIGHT_LUMINANCE_THRESHOLD
end

--- 对比度安全兜底：确保前景色 fg_rgba 在背景色 bg_rgba 上达到至少 min_ratio 的对比度
--- 若 fg_rgba 缺失或对比度不足（如第三方 PNG 皮肤缺失文字色配置），自动向高对比深色或浅色收敛
function theme.ensure_contrast(bg_rgba, fg_rgba, min_ratio)
  local target_ratio = tonumber(min_ratio) or theme.MIN_CONTRAST_RATIO
  local bg = tonumber(bg_rgba) or 0x1A1D23FF
  if type(fg_rgba) == "number" and theme.contrast_ratio(bg, fg_rgba) >= target_ratio then
    return fg_rgba
  end

  local dark_anchor = 0x14181FFF
  local light_anchor = 0xF4F7FBFF
  local dark_ratio = theme.contrast_ratio(bg, dark_anchor)
  local light_ratio = theme.contrast_ratio(bg, light_anchor)
  local anchor = (dark_ratio >= light_ratio) and dark_anchor or light_anchor

  -- 在中等灰背景 (L ≈ 0.16..0.21) 上，柔和深/浅锚点可能略低于 4.5；按需升级至纯黑/纯白确保数学上 100% 可达标
  if theme.contrast_ratio(bg, anchor) < target_ratio then
    local pure_black = 0x000000FF
    local pure_white = 0xFFFFFFFF
    anchor = (theme.contrast_ratio(bg, pure_black) >= theme.contrast_ratio(bg, pure_white))
      and pure_black
      or pure_white
  end

  if type(fg_rgba) == "number" then
    local _, _, _, orig_a = theme.unpack_rgba(fg_rgba)
    for step = 1, 8 do
      local candidate = theme.with_alpha(theme.blend_rgba(fg_rgba, anchor, step / 8.0), orig_a)
      if theme.contrast_ratio(bg, candidate) >= target_ratio then
        return candidate
      end
    end
    return theme.with_alpha(anchor, orig_a)
  end

  return anchor
end

--- 保留色相与通透饱和度的强调色亮度适配算法：
--- 若 accent_rgba 具备有效彩度（如浅色皮肤中的粉红点缀），仅沿 HSL 亮度轴收敛以满足对比度，避免向纯黑混合发灰变脏；
--- 若 accent_rgba 缺失或无彩度（灰白/纯黑），返回 nil 交由优雅默认色接管。
function theme.adapt_vivid_accent(bg_rgba, accent_rgba, min_ratio, is_light_bg)
  if type(accent_rgba) ~= "number" then
    return nil, nil
  end
  local r, g, b, a = theme.unpack_rgba(accent_rgba)
  local spread = math.max(r, g, b) - math.min(r, g, b)
  local h, s, l = theme.rgb_to_hsl(r, g, b)
  local is_pastel_tint = (l > 0.85 and spread >= 10 and s >= 0.22 and l <= 0.98)
  if not is_pastel_tint and (spread < 14 or s < 0.16 or l < 0.05 or l > 0.97) then
    return nil, nil
  end

  local target_ratio = tonumber(min_ratio) or 3.2
  local boosted_s = is_light_bg and math.max(s, 0.52) or math.max(s, 0.56)
  boosted_s = math.min(boosted_s, is_light_bg and 0.78 or 0.82)

  local cur_l = is_light_bg and math.min(l, 0.50) or math.max(l, 0.58)
  local candidate = theme.hsla(h, boosted_s, cur_l, a)
  if theme.contrast_ratio(bg_rgba, candidate) >= target_ratio then
    return candidate, h
  end

  -- 沿亮度轴单向步进（浅色底加深，深色底提亮），保持原始色相清澈
  for step = 1, 14 do
    local next_l
    if is_light_bg then
      next_l = cur_l * (1.0 - step / 15.0) + 0.16 * (step / 15.0)
    else
      next_l = cur_l + (0.86 - cur_l) * (step / 15.0)
    end
    candidate = theme.hsla(h, boosted_s, next_l, a)
    if theme.contrast_ratio(bg_rgba, candidate) >= target_ratio then
      return candidate, h
    end
  end

  return theme.ensure_contrast(bg_rgba, candidate, target_ratio), h
end

--- 计算适合叠加在强调色底面（如激活按钮、ON 胶囊）上的高对比文字色
function theme.on_accent_text(accent_bg_rgba)
  local white = 0xFFFFFFFF
  local ink = 0x161A22FF
  local w_ratio = theme.contrast_ratio(accent_bg_rgba, white)
  local i_ratio = theme.contrast_ratio(accent_bg_rgba, ink)
  if w_ratio >= i_ratio and w_ratio >= 4.5 then
    return white
  elseif i_ratio > w_ratio and i_ratio >= 4.5 then
    return ink
  end
  local pure_black = 0x000000FF
  if theme.contrast_ratio(accent_bg_rgba, pure_black) > w_ratio then
    return pure_black
  end
  return white
end

--------------------------------------------------------------------------------
-- 2. Studio Dark 默认配色与 REAPER 宿主主题自适应调色板
--------------------------------------------------------------------------------

--- 获取默认 Studio Dark 独立深色主题调色板
function theme.get_studio_dark_palette()
  return {
    mode = "studio_dark",
    is_light = false,
    host_accent_detected = false,

    -- ImGui 基础配色栈
    window_bg              = 0x16191FFF,
    child_bg               = 0x13161BFF,
    popup_bg               = 0x1C2028FA,
    border                 = 0x2C323EFF,
    frame_bg               = 0x222731FF,
    frame_bg_hovered       = 0x2C3340FF,
    frame_bg_active        = 0x353E4EFF,
    title_bg               = 0x12151AFF,
    title_bg_active        = 0x181C24FF,
    title_bg_collapsed     = 0x12151AE0,
    button                 = 0x252B37FF,
    button_hovered         = 0x323B4BFF,
    button_active          = 0x3E495DFF,
    header                 = 0x262D3AFF,
    header_hovered         = 0x313B4CFF,
    header_active          = 0x3B475CFF,
    separator              = 0x2A303CFF,
    text                   = 0xE6EAF0FF,
    text_disabled          = 0x7D8696FF,
    text_selected_bg       = 0x4E8DF54D,
    check_mark             = 0xE5A33BFF,
    slider_grab            = 0x4E8DF5FF,
    slider_grab_active     = 0x6BA1FAFF,
    scrollbar_bg           = 0x13161B88,
    scrollbar_grab         = 0x343C4BFF,
    scrollbar_grab_hovered = 0x455064FF,
    scrollbar_grab_active  = 0x57657EFF,
    tab                    = 0x1B1F27FF,
    tab_hovered            = 0x2C3443FF,
    tab_active             = 0x252C38FF,
    tab_unfocused          = 0x16191FFF,
    tab_unfocused_active   = 0x1E232DFF,
    resize_grip            = 0x4E8DF533,
    resize_grip_hovered    = 0x4E8DF588,
    resize_grip_active     = 0x4E8DF5CC,
    docking_preview        = 0x4E8DF588,
    docking_empty_bg       = 0x13161BFF,

    -- 顶部轨道栏
    header_bar_bg          = 0x1B1F27FF,
    header_bar_border      = 0x2B313DFF,
    track_badge_bg         = 0x272F3DFF,
    track_badge_text       = 0x9BB7E8FF,

    -- 双区差异化卡片与强调色（上半区 0 号位暖琥珀金 vs 下半区常规槽录音室冷蓝）
    strip_zone_bg          = 0x22201DFF,
    strip_zone_border      = 0x4A3B26FF,
    strip_accent           = 0xE5A33BFF,
    strip_accent_dim       = 0x6E5329FF,

    normal_zone_bg         = 0x1B2029FF,
    normal_zone_border     = 0x2B384EFF,
    normal_accent          = 0x4E8DF5FF,
    normal_accent_dim      = 0x2C4978FF,

    -- 上半区总 Bypass 胶囊开关
    master_on_bg           = 0xD99226FF,
    master_on_bg_hover     = 0xE8A43AFF,
    master_on_text         = 0x16191FFF,
    master_off_bg          = 0x2A2F3AFF,
    master_off_bg_hover    = 0x353C4AFF,
    master_off_text        = 0x8D96A6FF,

    -- 单行 FX 卡片与状态色
    row_bg_strip           = 0x202227FF,
    row_bg_normal          = 0x1C2027FF,
    row_border_strip       = 0x2E2C28FF,
    row_border_normal      = 0x262C36FF,
    row_bg_hover           = 0x282E3AFF,
    row_bg_open            = 0x263245FF,
    row_border_open        = 0x4E8DF5B8,
    row_text               = 0xE8ECF2FF,
    row_text_bypassed      = 0x707887FF,
    row_slot_strip         = 0xE8B054FF,
    row_slot_normal        = 0x72A7FAFF,

    -- 行尾删除按钮
    delete_icon            = 0x7C8596FF,
    delete_hover_bg        = 0xB9384840,
    delete_hover_icon      = 0xFF7B89FF,

    -- Bypass 指示灯
    bypass_socket          = 0x101317FF,
    bypass_on_strip        = 0xF5AD3BFF,
    bypass_on_normal       = 0x38C976FF,
    bypass_glow_strip      = 0xF5AD3B44,
    bypass_glow_normal     = 0x38C97644,
    bypass_off             = 0x454C59FF,

    -- 单行 MIX 圆弧旋钮 (Knob)
    knob_bg                = 0x13161CFF,
    knob_track             = 0x333A48FF,
    knob_ring_hover        = 0xE6EAF048,
    knob_arc_strip         = 0xE5A33BFF,
    knob_arc_normal        = 0x4E8DF5FF,
    knob_arc_bypassed      = 0x565E6DFF,
    knob_pointer           = 0xF0F4FAFF,
    knob_text              = 0xAEB7C6FF,
    knob_text_active       = 0xF5B958FF,
    knob_text_normal_active = 0x7EB0FFFF,

    -- 拖拽目标高亮插入线与热区底色
    drag_insert_line       = 0x52A8FFFF,
    drag_target_fill       = 0x4E8DF526,
    drop_zone_bg           = 0x4E8DF51A,
    drop_zone_border       = 0x4E8DF599,

    -- 偏离提示条
    warning_bg             = 0x332718FF,
    warning_border         = 0xD98A2BFF,
    warning_text           = 0xF7C97EFF,
  }
end

local function query_theme_raw(r_api, key)
  if not r_api or type(r_api.GetThemeColor) ~= "function" then
    return nil
  end
  local ok, raw_col = pcall(r_api.GetThemeColor, key, 0)
  if ok and type(raw_col) == "number" and raw_col >= 0 then
    return raw_col
  end
  return nil
end

local function query_first_theme_rgba(r_api, keys)
  for _, key in ipairs(keys) do
    local raw_col = query_theme_raw(r_api, key)
    if raw_col ~= nil then
      local rgba = theme.native_to_rgba(raw_col, 255, r_api)
      if rgba then
        return rgba, key, raw_col
      end
    end
  end
  return nil, nil, nil
end

--- 从多个 REAPER 主题高亮/选中键中优先挑选出具有清晰彩度（如粉红、湖蓝、珊瑚红）的宿主强调色
local function query_vivid_host_accent(r_api)
  local accent_keys = {
    "col_tcp_bgsel",
    "col_seltrack2",
    "col_seltrack",
    "col_main_hilite",
    "col_tl_bgsel",
    "selitem_dot",
    "marqueezoom_outline",
    "marqueezoom_fill",
  }
  local fallback_rgba = nil
  local sig_parts = {}
  for _, key in ipairs(accent_keys) do
    local raw_col = query_theme_raw(r_api, key)
    sig_parts[#sig_parts + 1] = tostring(raw_col or -1)
    if raw_col ~= nil then
      local rgba = theme.native_to_rgba(raw_col, 255, r_api)
      if rgba then
        if not fallback_rgba then
          fallback_rgba = rgba
        end
        local r, g, b = theme.unpack_rgba(rgba)
        local spread = math.max(r, g, b) - math.min(r, g, b)
        local _, s, l = theme.rgb_to_hsl(r, g, b)
        local is_pastel_tint = (l > 0.85 and spread >= 10 and s >= 0.22 and l <= 0.98)
        if is_pastel_tint or (spread >= 14 and s >= 0.18 and l >= 0.05 and l <= 0.97) then
          return rgba, table.concat(sig_parts, ",")
        end
      end
    end
  end
  return fallback_rgba, table.concat(sig_parts, ",")
end

--- 清除宿主配色缓存（测试或强制刷新用）
function theme.clear_host_cache()
  theme._host_cache_sig = nil
  theme._host_cache_palette = nil
end

--- 根据 REAPER 宿主当前主题（自动兼容明亮白/浅灰底 + 粉红等彩色点缀浅色皮肤与深色皮肤）构建安全调色板
function theme.build_host_palette(reaper_api)
  local r_api = reaper_api or _G.reaper

  local raw_bg2 = query_theme_raw(r_api, "col_main_bg2")
  local raw_tcp = query_theme_raw(r_api, "col_tcp_bg")
  local raw_bg1 = query_theme_raw(r_api, "col_main_bg")
  local raw_win = query_theme_raw(r_api, "window_bg")
  local raw_edit = query_theme_raw(r_api, "col_main_editbk")

  local host_text, _, raw_text = query_first_theme_rgba(r_api, {
    "col_main_text2",
    "col_tcp_text",
    "col_main_text",
    "window_text",
  })
  local host_accent_raw, accent_sig = query_vivid_host_accent(r_api)

  -- 缓存指纹：若宿主主题色未变直接复用，实现零每帧 GC 与换肤即时响应
  local sig = table.concat({
    tostring(raw_bg2 or -1),
    tostring(raw_tcp or -1),
    tostring(raw_bg1 or -1),
    tostring(raw_win or -1),
    tostring(raw_edit or -1),
    tostring(raw_text or -1),
    accent_sig or "",
  }, "|")
  if theme._host_cache_sig == sig and theme._host_cache_palette then
    return theme._host_cache_palette
  end

  local bg2_rgba = raw_bg2 and theme.native_to_rgba(raw_bg2, 255, r_api) or nil
  local tcp_rgba = raw_tcp and theme.native_to_rgba(raw_tcp, 255, r_api) or nil
  local bg1_rgba = raw_bg1 and theme.native_to_rgba(raw_bg1, 255, r_api) or nil
  local win_rgba = raw_win and theme.native_to_rgba(raw_win, 255, r_api) or nil
  local host_edit_bg = raw_edit and theme.native_to_rgba(raw_edit, 255, r_api) or nil

  -- 第三方 PNG 位图浅色皮肤容错：若 col_main_bg2 为占位纯黑 (L < 0.02)，但 tcp_bg 与 editbk 均为明亮浅色，优先取 tcp_bg
  local host_bg = bg2_rgba or tcp_rgba or bg1_rgba or win_rgba
  if bg2_rgba
    and theme.relative_luminance(bg2_rgba) < 0.02
    and tcp_rgba
    and theme.relative_luminance(tcp_rgba) > 0.45
    and (not host_edit_bg or theme.relative_luminance(host_edit_bg) > 0.45) then
    host_bg = tcp_rgba
  end

  if not host_bg then
    local fallback = theme.get_studio_dark_palette()
    theme._host_cache_sig = sig
    theme._host_cache_palette = fallback
    return fallback
  end

  local is_light = theme.is_light_color(host_bg)
  local bg_lum = theme.relative_luminance(host_bg)
  local safe_text = theme.ensure_contrast(host_bg, host_text, theme.MIN_CONTRAST_RATIO)

  local result_pal
  if is_light then
    -- 明亮白 / 浅灰底浅色宿主主题自适应派生（天然兼容白/浅灰 + 粉红等自定义浅色皮肤）
    local pure_white = 0xFFFFFFFF
    local neutral_gray = 0xD4D9E2FF
    local slate_border = 0xB8C0CCFF

    -- 宿主背景接近纯白 (L > 0.85) 时，卡片采用精致微浅灰表面；若背景本身为浅灰，卡片向纯净亮白抬升
    local card_base = (bg_lum > 0.85)
      and theme.blend_rgba(host_bg, 0xEDF0F5FF, 0.72)
      or theme.blend_rgba(host_bg, pure_white, 0.72)

    -- 优先通过 HSL 色相保持算法提取宿主彩色强调色（例如浅色粉红皮肤 -> 玫瑰粉强调色）
    local adapted_accent, accent_hue = theme.adapt_vivid_accent(card_base, host_accent_raw, 3.4, true)
    local has_vivid_accent = (adapted_accent ~= nil)
    local normal_accent = adapted_accent or 0x2563EBFF

    -- 上半区 0 号位 Channel Strip 保持暖琥珀金；若宿主强调色本身落入暖橙琥珀区 (20°..52°)，自动偏移至深莓紫以防双区撞色
    local strip_accent = 0xC47714FF
    if accent_hue and accent_hue >= 20.0 and accent_hue <= 52.0 then
      strip_accent = 0x9B3D7EFF
    end
    strip_accent = theme.ensure_contrast(card_base, strip_accent, 3.4)

    -- 清爽现代浅色卡片表面：极轻微的色相呼吸，靠清晰 1px 描边与左侧 3px 强调色条建立层级
    local row_strip_bg = theme.blend_rgba(card_base, strip_accent, 0.045)
    local row_normal_bg = theme.blend_rgba(card_base, normal_accent, 0.030)
    local row_border_strip = theme.blend_rgba(card_base, strip_accent, 0.24)
    local row_border_normal = theme.blend_rgba(card_base, slate_border, 0.55)
    local row_hover_bg = theme.blend_rgba(card_base, normal_accent, 0.10)
    local row_open_bg = theme.blend_rgba(card_base, normal_accent, 0.16)

    local frame_bg = host_edit_bg
      and theme.blend_rgba(host_bg, host_edit_bg, 0.65)
      or theme.blend_rgba(host_bg, pure_white, 0.65)
    -- 若 frame_bg 与 host_bg 几乎完全同色，稍微压暗一点保证输入框轮廓清晰
    if theme.contrast_ratio(host_bg, frame_bg) < 1.06 then
      frame_bg = theme.blend_rgba(host_bg, neutral_gray, 0.38)
    end

    local button_bg = theme.blend_rgba(host_bg, neutral_gray, 0.52)
    local button_hover = theme.blend_rgba(button_bg, normal_accent, 0.18)
    local button_active = theme.blend_rgba(button_bg, normal_accent, 0.30)
    local popup_bg = theme.with_alpha(theme.blend_rgba(host_bg, pure_white, 0.82), 252)

    -- 严格校验文字在全部关键浅色表面上的 WCAG 2.1 对比度 (>= 4.5)
    safe_text = theme.ensure_contrast(host_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(card_base, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(row_strip_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(row_normal_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(row_open_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(frame_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(button_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(popup_bg, safe_text, theme.MIN_CONTRAST_RATIO)

    local bypassed_text = theme.ensure_contrast(
      card_base,
      theme.blend_rgba(safe_text, card_base, 0.46),
      2.8
    )

    local strip_zone_bg = theme.blend_rgba(host_bg, strip_accent, 0.11)
    local normal_zone_bg = theme.blend_rgba(host_bg, normal_accent, 0.10)
    local header_bar_bg = theme.blend_rgba(host_bg, neutral_gray, 0.28)
    local master_on_bg = strip_accent
    local master_off_bg = theme.blend_rgba(host_bg, neutral_gray, 0.65)

    local slot_strip_col = theme.ensure_contrast(row_strip_bg, strip_accent, 4.2)
    local slot_normal_col = theme.ensure_contrast(row_normal_bg, normal_accent, 4.2)
    local drag_line_col = theme.ensure_contrast(host_bg, normal_accent, 3.6)

    result_pal = {
      mode = "host_light",
      is_light = true,
      host_accent_detected = has_vivid_accent,

      window_bg              = host_bg,
      child_bg               = theme.blend_rgba(host_bg, neutral_gray, 0.14),
      popup_bg               = popup_bg,
      border                 = theme.blend_rgba(host_bg, slate_border, 0.72),
      frame_bg               = frame_bg,
      frame_bg_hovered       = theme.blend_rgba(frame_bg, normal_accent, 0.12),
      frame_bg_active        = theme.blend_rgba(frame_bg, normal_accent, 0.20),
      title_bg               = theme.blend_rgba(host_bg, neutral_gray, 0.45),
      title_bg_active        = theme.blend_rgba(host_bg, normal_accent, 0.14),
      title_bg_collapsed     = theme.with_alpha(theme.blend_rgba(host_bg, neutral_gray, 0.45), 220),
      button                 = button_bg,
      button_hovered         = button_hover,
      button_active          = button_active,
      header                 = theme.blend_rgba(host_bg, normal_accent, 0.14),
      header_hovered         = theme.blend_rgba(host_bg, normal_accent, 0.22),
      header_active          = theme.blend_rgba(host_bg, normal_accent, 0.30),
      separator              = theme.blend_rgba(host_bg, slate_border, 0.55),
      text                   = safe_text,
      text_disabled          = bypassed_text,
      text_selected_bg       = theme.with_alpha(normal_accent, 64),
      check_mark             = normal_accent,
      slider_grab            = normal_accent,
      slider_grab_active     = theme.blend_rgba(normal_accent, 0x000000FF, 0.16),
      scrollbar_bg           = theme.with_alpha(theme.blend_rgba(host_bg, neutral_gray, 0.35), 140),
      scrollbar_grab         = theme.blend_rgba(host_bg, 0x8F9AA8FF, 0.52),
      scrollbar_grab_hovered = theme.blend_rgba(host_bg, normal_accent, 0.48),
      scrollbar_grab_active  = normal_accent,
      tab                    = theme.blend_rgba(host_bg, neutral_gray, 0.45),
      tab_hovered            = theme.blend_rgba(host_bg, normal_accent, 0.20),
      tab_active             = theme.blend_rgba(host_bg, pure_white, 0.85),
      tab_unfocused          = theme.blend_rgba(host_bg, neutral_gray, 0.35),
      tab_unfocused_active   = theme.blend_rgba(host_bg, pure_white, 0.65),
      resize_grip            = theme.with_alpha(normal_accent, 52),
      resize_grip_hovered    = theme.with_alpha(normal_accent, 140),
      resize_grip_active     = theme.with_alpha(normal_accent, 210),
      docking_preview        = theme.with_alpha(normal_accent, 128),
      docking_empty_bg       = theme.blend_rgba(host_bg, neutral_gray, 0.25),

      header_bar_bg          = header_bar_bg,
      header_bar_border      = theme.blend_rgba(host_bg, slate_border, 0.62),
      track_badge_bg         = theme.blend_rgba(host_bg, normal_accent, 0.14),
      track_badge_text       = theme.ensure_contrast(
        theme.blend_rgba(host_bg, normal_accent, 0.14),
        normal_accent,
        4.2
      ),

      strip_zone_bg          = strip_zone_bg,
      strip_zone_border      = theme.blend_rgba(host_bg, strip_accent, 0.42),
      strip_accent           = strip_accent,
      strip_accent_dim       = theme.blend_rgba(card_base, strip_accent, 0.34),

      normal_zone_bg         = normal_zone_bg,
      normal_zone_border     = theme.blend_rgba(host_bg, normal_accent, 0.38),
      normal_accent          = normal_accent,
      normal_accent_dim      = theme.blend_rgba(card_base, normal_accent, 0.30),

      master_on_bg           = master_on_bg,
      master_on_bg_hover     = theme.blend_rgba(master_on_bg, 0x000000FF, 0.10),
      master_on_text         = theme.on_accent_text(master_on_bg),
      master_off_bg          = master_off_bg,
      master_off_bg_hover    = theme.blend_rgba(master_off_bg, 0x000000FF, 0.08),
      master_off_text        = theme.ensure_contrast(master_off_bg, bypassed_text, 3.6),

      row_bg_strip           = row_strip_bg,
      row_bg_normal          = row_normal_bg,
      row_border_strip       = row_border_strip,
      row_border_normal      = row_border_normal,
      row_bg_hover           = row_hover_bg,
      row_bg_open            = row_open_bg,
      row_border_open        = theme.with_alpha(normal_accent, 196),
      row_text               = safe_text,
      row_text_bypassed      = bypassed_text,
      row_slot_strip         = slot_strip_col,
      row_slot_normal        = slot_normal_col,

      delete_icon            = bypassed_text,
      delete_hover_bg        = 0xE11D4826,
      delete_hover_icon      = 0xBE123CFF,

      bypass_socket          = theme.blend_rgba(card_base, 0x64748BFF, 0.34),
      bypass_on_strip        = 0xD97706FF,
      bypass_on_normal       = 0x16A34AFF,
      bypass_glow_strip      = 0xD977063A,
      bypass_glow_normal     = 0x16A34A3A,
      bypass_off             = theme.blend_rgba(card_base, 0x64748BFF, 0.52),

      knob_bg                = theme.blend_rgba(card_base, 0x94A3B8FF, 0.22),
      knob_track             = theme.blend_rgba(card_base, 0x64748BFF, 0.42),
      knob_ring_hover        = theme.with_alpha(normal_accent, 110),
      knob_arc_strip         = strip_accent,
      knob_arc_normal        = normal_accent,
      knob_arc_bypassed      = theme.blend_rgba(card_base, 0x64748BFF, 0.50),
      knob_pointer           = safe_text,
      knob_text              = theme.ensure_contrast(card_base, theme.blend_rgba(safe_text, card_base, 0.18), 4.0),
      knob_text_active       = slot_strip_col,
      knob_text_normal_active = slot_normal_col,

      drag_insert_line       = drag_line_col,
      drag_target_fill       = theme.with_alpha(normal_accent, 34),
      drop_zone_bg           = theme.with_alpha(normal_accent, 22),
      drop_zone_border       = theme.with_alpha(drag_line_col, 170),

      warning_bg             = 0xFEF3C7FF,
      warning_border         = 0xD97706FF,
      warning_text           = theme.ensure_contrast(0xFEF3C7FF, 0x92400EFF, 4.5),
    }
  else
    -- 深色宿主主题自适应派生（同时支持承接深色皮肤的彩色强调点缀）
    local base = theme.get_studio_dark_palette()
    local card_base = theme.blend_rgba(host_bg, 0x2E3542FF, 0.34)
    local frame_bg = host_edit_bg
      and theme.blend_rgba(host_bg, host_edit_bg, 0.55)
      or theme.blend_rgba(host_bg, 0x353D4CFF, 0.40)
    local button_bg = theme.blend_rgba(host_bg, 0x3B4454FF, 0.45)
    local popup_bg = theme.with_alpha(theme.blend_rgba(host_bg, 0x12151BFF, 0.38), 252)

    local adapted_accent, accent_hue = theme.adapt_vivid_accent(card_base, host_accent_raw, 3.6, false)
    local has_vivid_accent = (adapted_accent ~= nil)
    local normal_accent = adapted_accent or base.normal_accent
    local strip_accent = base.strip_accent
    if accent_hue and accent_hue >= 20.0 and accent_hue <= 52.0 then
      strip_accent = 0xD96BB8FF
    end

    local row_bg_strip = theme.blend_rgba(card_base, strip_accent, 0.06)
    local row_bg_hover = theme.blend_rgba(card_base, normal_accent, 0.14)
    local row_bg_open = theme.blend_rgba(card_base, normal_accent, 0.22)

    safe_text = theme.ensure_contrast(host_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(card_base, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(row_bg_strip, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(row_bg_open, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(frame_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(button_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(popup_bg, safe_text, theme.MIN_CONTRAST_RATIO)

    local bypassed_text = theme.ensure_contrast(
      card_base,
      theme.blend_rgba(safe_text, host_bg, 0.48),
      2.6
    )

    base.mode = "host_dark"
    base.is_light = false
    base.host_accent_detected = has_vivid_accent
    base.window_bg = host_bg
    base.child_bg = theme.blend_rgba(host_bg, 0x0E1014FF, 0.25)
    base.popup_bg = popup_bg
    base.border = theme.blend_rgba(host_bg, 0x5A6578FF, 0.36)
    base.frame_bg = frame_bg
    base.frame_bg_hovered = theme.blend_rgba(frame_bg, normal_accent, 0.16)
    base.frame_bg_active = theme.blend_rgba(frame_bg, normal_accent, 0.26)
    base.title_bg = theme.blend_rgba(host_bg, 0x0B0D11FF, 0.30)
    base.title_bg_active = theme.blend_rgba(host_bg, normal_accent, 0.12)
    base.title_bg_collapsed = theme.with_alpha(base.title_bg, 224)
    base.button = button_bg
    base.button_hovered = theme.blend_rgba(button_bg, normal_accent, 0.20)
    base.button_active = theme.blend_rgba(button_bg, normal_accent, 0.32)
    base.header = theme.blend_rgba(host_bg, normal_accent, 0.18)
    base.header_hovered = theme.blend_rgba(host_bg, normal_accent, 0.28)
    base.header_active = theme.blend_rgba(host_bg, normal_accent, 0.38)
    base.separator = theme.blend_rgba(host_bg, 0x566073FF, 0.34)
    base.text = safe_text
    base.text_disabled = bypassed_text
    base.text_selected_bg = theme.with_alpha(normal_accent, 76)
    base.check_mark = strip_accent
    base.slider_grab = normal_accent
    base.slider_grab_active = theme.blend_rgba(normal_accent, 0xFFFFFFFF, 0.18)
    base.scrollbar_bg = theme.with_alpha(base.child_bg, 140)
    base.scrollbar_grab = theme.blend_rgba(host_bg, 0x5B667AFF, 0.45)
    base.scrollbar_grab_hovered = theme.blend_rgba(host_bg, normal_accent, 0.50)
    base.scrollbar_grab_active = normal_accent
    base.tab = theme.blend_rgba(host_bg, 0x262C38FF, 0.40)
    base.tab_hovered = theme.blend_rgba(host_bg, normal_accent, 0.28)
    base.tab_active = theme.blend_rgba(host_bg, normal_accent, 0.22)
    base.tab_unfocused = host_bg
    base.tab_unfocused_active = theme.blend_rgba(host_bg, 0x2C3442FF, 0.45)
    base.resize_grip = theme.with_alpha(normal_accent, 52)
    base.resize_grip_hovered = theme.with_alpha(normal_accent, 136)
    base.resize_grip_active = theme.with_alpha(normal_accent, 204)
    base.docking_preview = theme.with_alpha(normal_accent, 136)
    base.docking_empty_bg = base.child_bg

    base.header_bar_bg = theme.blend_rgba(host_bg, 0x252B36FF, 0.38)
    base.header_bar_border = base.border
    base.track_badge_bg = theme.blend_rgba(host_bg, normal_accent, 0.22)
    base.track_badge_text = theme.ensure_contrast(base.track_badge_bg, normal_accent, 4.2)

    base.strip_accent = strip_accent
    base.strip_accent_dim = theme.blend_rgba(host_bg, strip_accent, 0.38)
    base.strip_zone_bg = theme.blend_rgba(host_bg, strip_accent, 0.12)
    base.strip_zone_border = theme.blend_rgba(host_bg, strip_accent, 0.36)

    base.normal_accent = normal_accent
    base.normal_accent_dim = theme.blend_rgba(host_bg, normal_accent, 0.36)
    base.normal_zone_bg = theme.blend_rgba(host_bg, normal_accent, 0.12)
    base.normal_zone_border = theme.blend_rgba(host_bg, normal_accent, 0.34)

    base.master_on_bg = strip_accent
    base.master_on_bg_hover = theme.blend_rgba(strip_accent, 0xFFFFFFFF, 0.12)
    base.master_on_text = theme.on_accent_text(strip_accent)
    base.master_off_bg = button_bg
    base.master_off_bg_hover = base.button_hovered
    base.master_off_text = bypassed_text

    base.row_bg_strip = row_bg_strip
    base.row_bg_normal = card_base
    base.row_border_strip = theme.blend_rgba(card_base, strip_accent, 0.22)
    base.row_border_normal = theme.blend_rgba(card_base, 0x4C576AFF, 0.34)
    base.row_bg_hover = row_bg_hover
    base.row_bg_open = row_bg_open
    base.row_border_open = theme.with_alpha(normal_accent, 190)
    base.row_text = safe_text
    base.row_text_bypassed = bypassed_text
    base.row_slot_strip = theme.ensure_contrast(base.row_bg_strip, strip_accent, 4.0)
    base.row_slot_normal = theme.ensure_contrast(base.row_bg_normal, normal_accent, 4.0)

    base.knob_bg = theme.blend_rgba(host_bg, 0x0D0F13FF, 0.45)
    base.knob_track = theme.blend_rgba(card_base, 0x5A6578FF, 0.44)
    base.knob_ring_hover = theme.with_alpha(safe_text, 80)
    base.knob_arc_strip = strip_accent
    base.knob_arc_normal = normal_accent
    base.knob_pointer = safe_text
    base.knob_text = theme.ensure_contrast(card_base, theme.blend_rgba(safe_text, host_bg, 0.18), 4.0)
    base.knob_text_active = base.row_slot_strip
    base.knob_text_normal_active = base.row_slot_normal

    base.drag_insert_line = theme.ensure_contrast(host_bg, normal_accent, 4.2)
    base.drag_target_fill = theme.with_alpha(normal_accent, 40)
    base.drop_zone_bg = theme.with_alpha(normal_accent, 26)
    base.drop_zone_border = theme.with_alpha(base.drag_insert_line, 170)

    result_pal = base
  end

  theme._host_cache_sig = sig
  theme._host_cache_palette = result_pal
  return result_pal
end

--- 根据 settings 解析当前应使用的调色板
function theme.resolve_palette(settings, reaper_api)
  if type(settings) == "table" and settings.follow_host_theme then
    return theme.build_host_palette(reaper_api)
  end
  if not theme._studio_dark_cache then
    theme._studio_dark_cache = theme.get_studio_dark_palette()
  end
  return theme._studio_dark_cache
end

--- 获取当前帧活跃调色板（若尚未 push 则即时解析）
function theme.get_palette(settings, reaper_api)
  if theme._active_palette then
    return theme._active_palette
  end
  return theme.resolve_palette(settings, reaper_api)
end

--------------------------------------------------------------------------------
-- 3. ReaImGui 样式压栈与弹栈（严格使用 rawget 探测并保证计数 100% 匹配）
--------------------------------------------------------------------------------

--- 压入当前主题的 ImGui 颜色栈与样式变量栈，返回实际压入的 color_count, var_count
function theme.push(ctx, ImGui, settings, reaper_api)
  local pal = theme.resolve_palette(settings, reaper_api)
  theme._active_palette = pal

  if not ctx or type(ImGui) ~= "table" then
    return 0, 0
  end

  local color_count = 0
  local var_count = 0

  if rawget(ImGui, "PushStyleColor") ~= nil then
    local color_entries = {
      { "Col_Text",                  pal.text },
      { "Col_TextDisabled",          pal.text_disabled },
      { "Col_TextSelectedBg",        pal.text_selected_bg },
      { "Col_WindowBg",              pal.window_bg },
      { "Col_ChildBg",               pal.child_bg },
      { "Col_PopupBg",               pal.popup_bg },
      { "Col_Border",                pal.border },
      { "Col_FrameBg",               pal.frame_bg },
      { "Col_FrameBgHovered",        pal.frame_bg_hovered },
      { "Col_FrameBgActive",         pal.frame_bg_active },
      { "Col_TitleBg",               pal.title_bg },
      { "Col_TitleBgActive",         pal.title_bg_active },
      { "Col_TitleBgCollapsed",      pal.title_bg_collapsed },
      { "Col_Button",                pal.button },
      { "Col_ButtonHovered",         pal.button_hovered },
      { "Col_ButtonActive",          pal.button_active },
      { "Col_Header",                pal.header },
      { "Col_HeaderHovered",         pal.header_hovered },
      { "Col_HeaderActive",          pal.header_active },
      { "Col_Separator",             pal.separator },
      { "Col_CheckMark",             pal.check_mark },
      { "Col_SliderGrab",            pal.slider_grab },
      { "Col_SliderGrabActive",      pal.slider_grab_active },
      { "Col_ScrollbarBg",           pal.scrollbar_bg },
      { "Col_ScrollbarGrab",         pal.scrollbar_grab },
      { "Col_ScrollbarGrabHovered",  pal.scrollbar_grab_hovered },
      { "Col_ScrollbarGrabActive",   pal.scrollbar_grab_active },
      { "Col_Tab",                   pal.tab },
      { "Col_TabHovered",            pal.tab_hovered },
      -- 兼容 ReaImGui 0.10 (TabSelected / TabDimmed) 与 0.9 (TabActive / TabUnfocused)，避免双键并存时重复压栈
      { (rawget(ImGui, "Col_TabSelected") ~= nil) and "Col_TabSelected" or "Col_TabActive",
        pal.tab_active },
      { (rawget(ImGui, "Col_TabDimmed") ~= nil) and "Col_TabDimmed" or "Col_TabUnfocused",
        pal.tab_unfocused },
      { (rawget(ImGui, "Col_TabDimmedSelected") ~= nil) and "Col_TabDimmedSelected" or "Col_TabUnfocusedActive",
        pal.tab_unfocused_active },
      { "Col_ResizeGrip",            pal.resize_grip },
      { "Col_ResizeGripHovered",     pal.resize_grip_hovered },
      { "Col_ResizeGripActive",      pal.resize_grip_active },
      { "Col_DockingPreview",        pal.docking_preview },
      { "Col_DockingEmptyBg",        pal.docking_empty_bg },
    }
    for _, entry in ipairs(color_entries) do
      local raw_col_enum = rawget(ImGui, entry[1])
      if raw_col_enum ~= nil and type(entry[2]) == "number" then
        ImGui.PushStyleColor(ctx, enum_val(raw_col_enum), entry[2])
        color_count = color_count + 1
      end
    end
  end

  if rawget(ImGui, "PushStyleVar") ~= nil then
    -- 单浮点数 StyleVar
    local scalar_vars = {
      { "StyleVar_WindowRounding",   4.0 },
      { "StyleVar_ChildRounding",    4.0 },
      { "StyleVar_FrameRounding",    3.0 },
      { "StyleVar_PopupRounding",    5.0 },
      { "StyleVar_GrabRounding",     3.0 },
      { "StyleVar_ScrollbarRounding", 4.0 },
      { "StyleVar_ScrollbarSize",    10.0 },
      { "StyleVar_WindowBorderSize", 1.0 },
      { "StyleVar_PopupBorderSize",  1.0 },
      { "StyleVar_FrameBorderSize",  0.0 },
    }
    for _, entry in ipairs(scalar_vars) do
      local raw_var_enum = rawget(ImGui, entry[1])
      if raw_var_enum ~= nil then
        ImGui.PushStyleVar(ctx, enum_val(raw_var_enum), entry[2])
        var_count = var_count + 1
      end
    end

    -- 双浮点数 (ImVec2) StyleVar
    local vec2_vars = {
      { "StyleVar_WindowPadding",     8.0, 8.0 },
      { "StyleVar_FramePadding",      6.0, 3.0 },
      { "StyleVar_ItemSpacing",       5.0, 4.0 },
      { "StyleVar_ItemInnerSpacing",  4.0, 3.0 },
    }
    for _, entry in ipairs(vec2_vars) do
      local raw_var_enum = rawget(ImGui, entry[1])
      if raw_var_enum ~= nil then
        ImGui.PushStyleVar(ctx, enum_val(raw_var_enum), entry[2], entry[3])
        var_count = var_count + 1
      end
    end
  end

  return color_count, var_count
end

--- 弹出配色与样式栈（数量为 0 时无操作）
function theme.pop(ctx, ImGui, color_count, var_count)
  if not ctx or type(ImGui) ~= "table" then
    return
  end
  if type(color_count) == "number" and color_count > 0 and rawget(ImGui, "PopStyleColor") ~= nil then
    ImGui.PopStyleColor(ctx, color_count)
  end
  if type(var_count) == "number" and var_count > 0 and rawget(ImGui, "PopStyleVar") ~= nil then
    ImGui.PopStyleVar(ctx, var_count)
  end
end

return theme
