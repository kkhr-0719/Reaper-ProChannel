-- src/theme.lua
-- Reaper ProChannel (ReaPCh) — Studio Dark 视觉体系与可选 REAPER 宿主主题配色适配层
-- 职责：
--   1. 提供默认 Studio Dark 低饱和中性深色配色栈、圆角/紧凑间距常量，以及上下双区（0 号位 Channel Strip / 常规 FX 槽）差异化视觉语义色；
--   2. 提供实验性“跟随 REAPER 宿主主题配色”支持（读取 reaper.GetThemeColor 并通过 ColorFromNative 转换为 ReaImGui 0xRRGGBBAA 格式），
--      自动识别明亮白/浅灰底浅色主题与深色主题，并内置基于 WCAG 2.1 相对亮度（Relative Luminance）与对比度（Contrast Ratio）的安全兜底；
--   3. 所有颜色转换与对比度兜底函数均为零 ImGui 依赖的纯函数，可脱离宿主在 tests/run.lua 中独立验证。

local theme = {}

theme.DEFAULT_WINDOW_WIDTH = 310
theme.DEFAULT_WINDOW_HEIGHT = 640
theme.MIN_CONTRAST_RATIO = 4.5
theme.LIGHT_LUMINANCE_THRESHOLD = 0.22

theme._active_palette = nil

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
-- 1. 纯 Lua 颜色转换、相对亮度与对比度安全兜底算法（可脱离 ImGui 独立单测）
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
  local anchor = (theme.contrast_ratio(bg, dark_anchor) >= theme.contrast_ratio(bg, light_anchor))
    and dark_anchor
    or light_anchor

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

--------------------------------------------------------------------------------
-- 2. Studio Dark 默认配色与 REAPER 宿主主题自适应调色板
--------------------------------------------------------------------------------

--- 获取默认 Studio Dark 独立深色主题调色板
function theme.get_studio_dark_palette()
  return {
    mode = "studio_dark",
    is_light = false,

    -- ImGui 基础配色栈
    window_bg         = 0x16191FFF,
    child_bg          = 0x13161BFF,
    popup_bg          = 0x1C2028FA,
    border            = 0x2C323EFF,
    frame_bg          = 0x222731FF,
    frame_bg_hovered  = 0x2C3340FF,
    frame_bg_active   = 0x353E4EFF,
    title_bg          = 0x12151AFF,
    title_bg_active   = 0x181C24FF,
    button            = 0x252B37FF,
    button_hovered    = 0x323B4BFF,
    button_active     = 0x3E495DFF,
    header            = 0x262D3AFF,
    header_hovered    = 0x313B4CFF,
    header_active     = 0x3B475CFF,
    separator         = 0x2A303CFF,
    text              = 0xE6EAF0FF,
    text_disabled     = 0x7D8696FF,
    check_mark        = 0xE5A33BFF,
    slider_grab       = 0x4E8DF5FF,
    slider_grab_active = 0x6BA1FAFF,

    -- 双区差异化卡片与强调色（上半区 0 号位暖琥珀金 vs 下半区常规槽录音室冷蓝）
    strip_zone_bg     = 0x22201DFF,
    strip_zone_border = 0x4A3B26FF,
    strip_accent      = 0xE5A33BFF,
    strip_accent_dim  = 0x6E5329FF,

    normal_zone_bg    = 0x1B2029FF,
    normal_zone_border = 0x2B384EFF,
    normal_accent     = 0x4E8DF5FF,
    normal_accent_dim = 0x2C4978FF,

    -- 单行 FX 卡片与状态色
    row_bg_strip      = 0x202227FF,
    row_bg_normal     = 0x1C2027FF,
    row_bg_hover      = 0x282E3AFF,
    row_bg_open       = 0x283347FF,
    row_border_open   = 0x4E8DF5AA,
    row_text          = 0xE8ECF2FF,
    row_text_bypassed = 0x707887FF,
    row_slot_strip    = 0xE8B054FF,
    row_slot_normal   = 0x72A7FAFF,

    -- Bypass 指示灯
    bypass_socket     = 0x101317FF,
    bypass_on_strip   = 0xF5AD3BFF,
    bypass_on_normal  = 0x38C976FF,
    bypass_glow_strip = 0xF5AD3B44,
    bypass_glow_normal = 0x38C97644,
    bypass_off        = 0x454C59FF,

    -- 单行 MIX 圆弧旋钮 (Knob)
    knob_bg           = 0x13161CFF,
    knob_track        = 0x333A48FF,
    knob_arc_strip    = 0xE5A33BFF,
    knob_arc_normal   = 0x4E8DF5FF,
    knob_arc_bypassed = 0x565E6DFF,
    knob_pointer      = 0xF0F4FAFF,
    knob_text         = 0xC5CCD8FF,
    knob_text_active  = 0xF5B958FF,

    -- 拖拽目标高亮插入线与热区底色
    drag_insert_line  = 0x52A8FFFF,
    drag_target_fill  = 0x4E8DF526,

    -- 偏离提示条
    warning_bg        = 0x332718FF,
    warning_border    = 0xD98A2BFF,
    warning_text      = 0xF7C97EFF,
  }
end

local function query_first_theme_rgba(r_api, keys)
  if not r_api or type(r_api.GetThemeColor) ~= "function" then
    return nil
  end
  for _, key in ipairs(keys) do
    local ok, raw_col = pcall(r_api.GetThemeColor, key, 0)
    if ok and type(raw_col) == "number" and raw_col >= 0 then
      local rgba = theme.native_to_rgba(raw_col, 255, r_api)
      if rgba then
        return rgba, key
      end
    end
  end
  return nil, nil
end

--- 根据 REAPER 宿主当前主题（自动兼容明亮白/浅灰底浅色皮肤与深色皮肤）构建安全调色板
function theme.build_host_palette(reaper_api)
  local r_api = reaper_api or _G.reaper
  local host_bg = query_first_theme_rgba(r_api, {
    "col_main_bg2",
    "col_tcp_bg",
    "col_main_bg",
    "window_bg",
  })

  if not host_bg then
    return theme.get_studio_dark_palette()
  end

  local host_text = query_first_theme_rgba(r_api, {
    "col_main_text2",
    "col_tcp_text",
    "col_main_text",
    "window_text",
  })
  local host_edit_bg = query_first_theme_rgba(r_api, {
    "col_main_editbk",
  })
  local host_accent = query_first_theme_rgba(r_api, {
    "col_tcp_bgsel",
    "col_main_hilite",
    "selitem_dot",
  })

  local is_light = theme.is_light_color(host_bg)
  local bg_lum = theme.relative_luminance(host_bg)

  -- 确保主文字在宿主背景上具备充足对比度 (>= 4.5)
  local safe_text = theme.ensure_contrast(host_bg, host_text, theme.MIN_CONTRAST_RATIO)

  if is_light then
    -- 明亮白 / 浅灰底浅色宿主主题自适应派生
    local pure_white = 0xFFFFFFFF
    local cool_slate = 0xCBD2DCFF
    local dark_border = 0xAEB7C4FF

    -- 若宿主背景已接近纯白 (L > 0.85)，卡片底色向微灰收敛以保持卡片边界清晰；否则向亮白抬升
    local card_base = (bg_lum > 0.85)
      and theme.blend_rgba(host_bg, 0xE2E6EEFF, 0.45)
      or theme.blend_rgba(host_bg, pure_white, 0.55)

    local row_strip_bg = theme.blend_rgba(card_base, 0xF5E6CCFF, 0.30)
    local row_normal_bg = theme.blend_rgba(card_base, 0xE4ECF7FF, 0.25)
    local row_hover_bg = theme.blend_rgba(card_base, 0xC8D4E6FF, 0.45)
    local row_open_bg = theme.blend_rgba(card_base, 0xB8D0F5FF, 0.50)

    local frame_bg = host_edit_bg
      and theme.blend_rgba(host_bg, host_edit_bg, 0.65)
      or theme.blend_rgba(host_bg, cool_slate, 0.40)
    local button_bg = theme.blend_rgba(host_bg, cool_slate, 0.45)
    local button_hover = theme.blend_rgba(host_bg, 0x9AA6B8FF, 0.50)
    local button_active = theme.blend_rgba(host_bg, 0x8291A6FF, 0.60)
    local popup_bg = theme.with_alpha(theme.blend_rgba(host_bg, pure_white, 0.70), 250)

    -- 再次校验文字在卡片、输入框、按钮、弹窗背景上的对比度，防止浅色卡片冲淡文字
    safe_text = theme.ensure_contrast(card_base, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(frame_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(button_bg, safe_text, theme.MIN_CONTRAST_RATIO)
    safe_text = theme.ensure_contrast(popup_bg, safe_text, theme.MIN_CONTRAST_RATIO)

    local bypassed_text = theme.ensure_contrast(
      card_base,
      theme.blend_rgba(safe_text, card_base, 0.45),
      2.6
    )

    local strip_accent = 0xC47A18FF
    local normal_accent = host_accent
      and theme.ensure_contrast(card_base, host_accent, 2.8)
      or 0x2563EBFF

    return {
      mode = "host_light",
      is_light = true,

      window_bg         = host_bg,
      child_bg          = theme.blend_rgba(host_bg, cool_slate, 0.18),
      popup_bg          = popup_bg,
      border            = theme.blend_rgba(host_bg, dark_border, 0.65),
      frame_bg          = frame_bg,
      frame_bg_hovered  = button_hover,
      frame_bg_active   = button_active,
      title_bg          = theme.blend_rgba(host_bg, cool_slate, 0.35),
      title_bg_active   = theme.blend_rgba(host_bg, cool_slate, 0.50),
      button            = button_bg,
      button_hovered    = button_hover,
      button_active     = button_active,
      header            = theme.blend_rgba(host_bg, 0xB8C7DCFF, 0.45),
      header_hovered    = theme.blend_rgba(host_bg, 0x9FB4D1FF, 0.55),
      header_active     = theme.blend_rgba(host_bg, 0x88A2C6FF, 0.65),
      separator         = theme.blend_rgba(host_bg, dark_border, 0.55),
      text              = safe_text,
      text_disabled     = bypassed_text,
      check_mark        = strip_accent,
      slider_grab       = normal_accent,
      slider_grab_active = theme.blend_rgba(normal_accent, 0x000000FF, 0.15),

      strip_zone_bg     = theme.blend_rgba(host_bg, 0xF2DFC2FF, 0.48),
      strip_zone_border = theme.blend_rgba(host_bg, strip_accent, 0.42),
      strip_accent      = strip_accent,
      strip_accent_dim  = theme.blend_rgba(host_bg, strip_accent, 0.35),

      normal_zone_bg    = theme.blend_rgba(host_bg, 0xD8E5F7FF, 0.48),
      normal_zone_border = theme.blend_rgba(host_bg, normal_accent, 0.38),
      normal_accent     = normal_accent,
      normal_accent_dim = theme.blend_rgba(host_bg, normal_accent, 0.32),

      row_bg_strip      = row_strip_bg,
      row_bg_normal     = row_normal_bg,
      row_bg_hover      = row_hover_bg,
      row_bg_open       = row_open_bg,
      row_border_open   = theme.with_alpha(normal_accent, 180),
      row_text          = safe_text,
      row_text_bypassed = bypassed_text,
      row_slot_strip    = theme.ensure_contrast(row_strip_bg, 0x9E5E08FF, 3.5),
      row_slot_normal   = theme.ensure_contrast(row_normal_bg, 0x1D4ED8FF, 3.5),

      bypass_socket     = theme.blend_rgba(card_base, 0x64748BFF, 0.35),
      bypass_on_strip   = 0xD97706FF,
      bypass_on_normal  = 0x16A34AFF,
      bypass_glow_strip = 0xD9770638,
      bypass_glow_normal = 0x16A34A38,
      bypass_off        = theme.blend_rgba(card_base, 0x64748BFF, 0.50),

      knob_bg           = theme.blend_rgba(card_base, 0x94A3B8FF, 0.28),
      knob_track        = theme.blend_rgba(card_base, 0x64748BFF, 0.48),
      knob_arc_strip    = strip_accent,
      knob_arc_normal   = normal_accent,
      knob_arc_bypassed = theme.blend_rgba(card_base, 0x64748BFF, 0.55),
      knob_pointer      = safe_text,
      knob_text         = safe_text,
      knob_text_active  = theme.ensure_contrast(card_base, strip_accent, 3.8),

      drag_insert_line  = 0x1D4ED8FF,
      drag_target_fill  = 0x2563EB24,

      warning_bg        = 0xFEF3C7FF,
      warning_border    = 0xD97706FF,
      warning_text      = theme.ensure_contrast(0xFEF3C7FF, 0x92400EFF, 4.5),
    }
  end

  -- 深色宿主主题自适应派生
  local base = theme.get_studio_dark_palette()
  local card_base = theme.blend_rgba(host_bg, 0x2E3542FF, 0.32)
  local frame_bg = theme.blend_rgba(host_bg, 0x353D4CFF, 0.40)
  local button_bg = theme.blend_rgba(host_bg, 0x3B4454FF, 0.45)
  local popup_bg = theme.with_alpha(theme.blend_rgba(host_bg, 0x14171DFF, 0.35), 250)

  safe_text = theme.ensure_contrast(card_base, safe_text, theme.MIN_CONTRAST_RATIO)
  safe_text = theme.ensure_contrast(frame_bg, safe_text, theme.MIN_CONTRAST_RATIO)
  safe_text = theme.ensure_contrast(button_bg, safe_text, theme.MIN_CONTRAST_RATIO)

  local bypassed_text = theme.ensure_contrast(
    card_base,
    theme.blend_rgba(safe_text, host_bg, 0.48),
    2.5
  )

  base.mode = "host_dark"
  base.is_light = false
  base.window_bg = host_bg
  base.child_bg = theme.blend_rgba(host_bg, 0x0E1014FF, 0.25)
  base.popup_bg = popup_bg
  base.border = theme.blend_rgba(host_bg, 0x5A6578FF, 0.35)
  base.frame_bg = frame_bg
  base.frame_bg_hovered = theme.blend_rgba(frame_bg, 0x5A677FFF, 0.35)
  base.frame_bg_active = theme.blend_rgba(frame_bg, 0x6E7F9EFF, 0.45)
  base.button = button_bg
  base.button_hovered = theme.blend_rgba(button_bg, 0x5E6C85FF, 0.35)
  base.button_active = theme.blend_rgba(button_bg, 0x7586A6FF, 0.45)
  base.separator = theme.blend_rgba(host_bg, 0x566073FF, 0.32)
  base.text = safe_text
  base.text_disabled = bypassed_text

  base.strip_zone_bg = theme.blend_rgba(host_bg, 0x3B2F1EFF, 0.38)
  base.normal_zone_bg = theme.blend_rgba(host_bg, 0x1E2B3DFF, 0.38)
  base.row_bg_strip = theme.blend_rgba(card_base, 0x362C20FF, 0.24)
  base.row_bg_normal = card_base
  base.row_bg_hover = theme.blend_rgba(card_base, 0x4A5568FF, 0.35)
  base.row_bg_open = theme.blend_rgba(card_base, 0x38537AFF, 0.45)
  base.row_text = safe_text
  base.row_text_bypassed = bypassed_text
  base.knob_bg = theme.blend_rgba(host_bg, 0x0D0F13FF, 0.45)
  base.knob_track = theme.blend_rgba(card_base, 0x5A6578FF, 0.42)
  base.knob_pointer = safe_text
  base.knob_text = theme.blend_rgba(safe_text, host_bg, 0.18)

  return base
end

--- 根据 settings 解析当前应使用的调色板
function theme.resolve_palette(settings, reaper_api)
  if type(settings) == "table" and settings.follow_host_theme then
    return theme.build_host_palette(reaper_api)
  end
  return theme.get_studio_dark_palette()
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
      { "Col_Text",             pal.text },
      { "Col_TextDisabled",     pal.text_disabled },
      { "Col_WindowBg",         pal.window_bg },
      { "Col_ChildBg",          pal.child_bg },
      { "Col_PopupBg",          pal.popup_bg },
      { "Col_Border",           pal.border },
      { "Col_FrameBg",          pal.frame_bg },
      { "Col_FrameBgHovered",   pal.frame_bg_hovered },
      { "Col_FrameBgActive",    pal.frame_bg_active },
      { "Col_TitleBg",          pal.title_bg },
      { "Col_TitleBgActive",    pal.title_bg_active },
      { "Col_Button",           pal.button },
      { "Col_ButtonHovered",    pal.button_hovered },
      { "Col_ButtonActive",     pal.button_active },
      { "Col_Header",           pal.header },
      { "Col_HeaderHovered",    pal.header_hovered },
      { "Col_HeaderActive",     pal.header_active },
      { "Col_Separator",        pal.separator },
      { "Col_CheckMark",        pal.check_mark },
      { "Col_SliderGrab",       pal.slider_grab },
      { "Col_SliderGrabActive", pal.slider_grab_active },
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
      { "StyleVar_PopupRounding",    4.0 },
      { "StyleVar_GrabRounding",     3.0 },
      { "StyleVar_WindowBorderSize", 1.0 },
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
