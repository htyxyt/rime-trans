-- 获取用户文件路径，并将路径中的\替换成/，以兼容Linux
local rime_user_path = string.gsub(rime_api.get_user_data_dir(), '\\', '/')
-- 设置simplehttp.dll的存放路径（用户目录下的simplehttp文件夹）
local lua_dir = rime_user_path .. "/lua/"

-- 统一添加 .dll 和 .so 支持（跨平台）
if lua_dir ~= "" then
    if lua_dir:sub(-1) ~= "/" then
        lua_dir = lua_dir .. "/"
    end
    
    package.cpath = string.format(
        "%s;%s?.dll;%s?.so",
        package.cpath,
        lua_dir,
        lua_dir
    )
end

local http = require("simplehttp")
local json = require("json")

-- 翻译API配置
local config = {
    -- 选择使用的翻译API: "google", "deepl", "microsoft", "deeplx", "niutrans"
    default_api = "niutrans", -- 默认使用小牛云翻译API
    
    -- API密钥配置
    api_keys = {
        deepl = "", -- 替换为您的DeepL API密钥
        microsoft = {
            key = "", -- 替换为您的Microsoft Translator API密钥
            region = "global" -- 替换为您的区域
        },
        niutrans = "" -- 替换为您的小牛云翻译API密钥
    },
    
    -- DeepLX服务器地址
    -- 请选择一个可用的服务器并取消注释，或者添加您自己的服务器
    deeplx_url = "",
    deeplx_token = nil,
}

-- 从方案配置中获取用户设置
local function get_user_config(env)
    local schema_config = env.engine.schema.config
    
    -- 创建用户配置表（初始值为默认配置）
    local user_config = {
        default_api = config.default_api,
        deeplx_url = config.deeplx_url,
        deeplx_token = config.deeplx_token,
        api_keys = {
            deepl = config.api_keys.deepl,
            microsoft = {
                key = config.api_keys.microsoft.key,
                region = config.api_keys.microsoft.region
            },
            niutrans = config.api_keys.niutrans
        }
    }
    
    -- 覆盖用户设置（如果存在）
    local function get_config_value(path, default)
        return schema_config:get_string(path) or default
    end
    
    -- 读取配置项
    user_config.default_api = get_config_value("cloud_translation/default_api", user_config.default_api)
    user_config.deeplx_url = get_config_value("cloud_translation/deeplx_url", user_config.deeplx_url)
    user_config.deeplx_token = get_config_value("cloud_translation/deeplx_token", user_config.deeplx_token)
    
    -- API密钥
    user_config.api_keys.deepl = get_config_value("cloud_translation/api_keys/deepl", user_config.api_keys.deepl)
    user_config.api_keys.microsoft.key = get_config_value("cloud_translation/api_keys/microsoft/key", user_config.api_keys.microsoft.key)
    user_config.api_keys.microsoft.region = get_config_value("cloud_translation/api_keys/microsoft/region", user_config.api_keys.microsoft.region)
    user_config.api_keys.niutrans = get_config_value("cloud_translation/api_keys/niutrans", user_config.api_keys.niutrans)
    
    return user_config
end

-- 获取API显示名称
local function get_api_display_name(api_key)
    local api_name_map = {
        google = "谷歌翻译",
        deepl = "DeepL翻译",
        microsoft = "微软翻译",
        deeplx = "DeepLX翻译",
        niutrans = "小牛翻译"
    }
    return api_name_map[api_key] or api_key
end

-- URL编码函数
local function url_encode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])",
            function(c)
                return string.format("%%%02X", string.byte(c))
            end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

-- Google翻译API
local function google(text)
    local encoded_text = url_encode(text)
    local url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&dt=bd&dt=rm&dt=qca&dt=at&dt=ss&dt=md&dt=ld&dt=ex&dj=1&q=" .. encoded_text
    
    local reply = http.request(url)
    local success, j = pcall(json.decode, reply)
    
    if success and j then
        if j.dict and j.dict[1] and j.dict[1].terms and j.dict[1].terms[1] then
            return j.dict[1].terms[1]
        end
        if j.sentences and j.sentences[1] and j.sentences[1].trans then
            return j.sentences[1].trans
        end
    end
    
    if reply then
        local _, _, terms = string.find(reply, '"terms":%[%"([^"]+)"')
        if terms then
            return terms
        end
        
        local _, _, translated = string.find(reply, '"trans":"([^"]+)"')
        if translated then
            return translated
        end
        
        local _, _, translated2 = string.find(reply, '%[%[%["([^"]+)"')
        if translated2 then
            return translated2
        end
    end
    
    return nil
end

-- DeepL翻译API
local function deepl(text, config)
    local api_key = config.api_keys.deepl
    if api_key == nil or api_key == "" then
        return nil
    end
    
    local url = "https://api-free.deepl.com/v2/translate"
    local body = "auth_key=" .. api_key .. "&text=" .. url_encode(text) .. "&target_lang=EN"
    
    local headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded"
    }
    
    local reply = http.request{
        url = url,
        method = "POST",
        headers = headers,
        data = body
    }
    local success, j = pcall(json.decode, reply)
    
    if success and j and j.translations and j.translations[1] and j.translations[1].text then
        return j.translations[1].text
    end
    
    return nil
end

-- Microsoft翻译API
local function microsoft(text, config)
    local api_key = config.api_keys.microsoft.key
    local region = config.api_keys.microsoft.region
    
    if api_key == nil or api_key == "" then
        return nil
    end
    
    local url = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=en"
    local body = json.encode({
        {["Text"] = text}
    })
    
    local headers = {
        ["Content-Type"] = "application/json",
        ["Ocp-Apim-Subscription-Key"] = api_key,
        ["Ocp-Apim-Subscription-Region"] = region
    }
    
    local reply = http.request{
        url = url,
        method = "POST",
        headers = headers,
        data = body
    }
    local success, j = pcall(json.decode, reply)
    
    if success and j and j[1] and j[1].translations and j[1].translations[1] and j[1].translations[1].text then
        return j[1].translations[1].text
    end
    
    return nil
end

-- DeepLX翻译API
local function deeplx(text, config)
    local url = config.deeplx_url
    
    if not url or url == "" then
        return nil
    end
    
    if type(text) ~= "string" then
        text = tostring(text)
    end
    
    local body_table = {
        text = text,
        source_lang = "ZH", 
        target_lang = "EN"
    }
    
    local success_encode, body = pcall(json.encode, body_table)
    if not success_encode then
        return nil
    end
    
    local headers = {
        ["Content-Type"] = "application/json"
    }
    
    if config.deeplx_token and config.deeplx_token ~= "" then
        headers["Authorization"] = "Bearer " .. config.deeplx_token
    end
    
    local success_request, reply = pcall(function()
        return http.request{
            url = url,
            method = "POST",
            headers = headers,
            data = body
        }
    end)
    
    if not success_request or not reply or reply == "" then
        return nil
    end
    
    local success_decode, j = pcall(json.decode, reply)
    
    if not success_decode then
        return nil
    end
    
    if j and j.data then
        return j.data
    elseif j and j.alternatives and j.alternatives[1] then
        return j.alternatives[1]
    elseif j and j.translation then
        return j.translation
    elseif j and j.translatedText then
        return j.translatedText
    end
    
    return nil
end

-- 小牛云翻译API
local function niutrans(text, config)
    local api_key = config.api_keys.niutrans
    
    if api_key == nil or api_key == "" then
        return nil
    end
    
    local url = "https://api.niutrans.com/NiuTransServer/translation"

    local body = json.encode({
        from = "zh",
        to = "en",
        apikey = api_key,
        src_text = text
    })
    
    local headers = {
        ["Content-Type"] = "application/json"
    }
    
    local reply = http.request{
        url = url,
        method = "POST",
        headers = headers,
        data = body
    }
    
    if not reply or reply == "" then
        return nil
    end
    
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil
    end
    
    if j.tgt_text then
        if type(j.tgt_text) == "string" then
            return j.tgt_text
        elseif type(j.tgt_text) == "table" then
            if j.tgt_text.content then
                return j.tgt_text.content
            else
                for k, v in pairs(j.tgt_text) do
                    if type(v) == "string" then
                        return v
                    end
                end
                return nil
            end
        else
            return nil
        end
    elseif j.translation then
        return j.translation
    elseif j.result and j.result.translatedText then
        return j.result.translatedText
    else
        return nil
    end
end

-- 翻译选择函数
local function trans(text, config)
    local result
    
    if config.default_api == "google" then
        result = google(text)
    elseif config.default_api == "deepl" then
        result = deepl(text, config)
    elseif config.default_api == "microsoft" then
        result = microsoft(text, config)
    elseif config.default_api == "deeplx" then
        result = deeplx(text, config)
    elseif config.default_api == "niutrans" then
        result = niutrans(text, config)
    else
        result = google(text)
    end
    
    return result
end

-- 判断是否为中文字符
local function is_chinese_character(char)
    local code = utf8.codepoint(char)
    return code >= 0x4E00 and code <= 0x9FFF
end

-- 主过滤器函数
local function filter(input, env)
    local input_text = env.engine.context.input

    if input_text:sub(-2) == "''" then
        -- 获取翻译配置（合并默认和用户设置）
        local config = get_user_config(env)
        local api_display_name = get_api_display_name(config.default_api)
        
        local raw_input = {}
        local count = 0
        
        for cand in input:iter() do
            if not cand.text then
                goto continue
            end
            
            local first_char = utf8.char(utf8.codepoint(cand.text))
            -- 超过30个汉字则不处理
            if is_chinese_character(first_char) then
                if count < 30 then
                    count = count + 1
                    table.insert(raw_input, cand.text)
                else
                    break
                end
            end
            
            ::continue::
        end
        
        if #raw_input == 0 then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        
        local translated_text = trans(raw_input[1], config)
        
        if not translated_text then
            yield(Candidate("error", 0, #input_text, "[翻译失败]", "请检查网络或API配置"))
            
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        
        -- 设置提示信息
        local composition = env.engine.context.composition
        if not composition:empty() then
            local segment = composition:back()
            segment.prompt = "〔" .. api_display_name .. "〕"
        end
        
        -- 创建候选词
        yield(Candidate("translation", 0, #input_text, translated_text, "[译] " .. raw_input[1]))
        
        for cand in input:iter() do
            yield(cand)
        end
    else
        for cand in input:iter() do
            yield(cand)
        end
    end
end

return filter