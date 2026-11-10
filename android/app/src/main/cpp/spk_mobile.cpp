/*  spk_mobile.cpp -- the dart:ffi face of the Spektrafilm engine.
 *
 *  The engine already exposes a hand-written C ABI (spk_engine.h) whose
 *  parameters cross as JSON and whose pixels cross as buffers. That is the
 *  same contract the macOS and Windows front ends use, so this file adds only
 *  what a phone needs to answer "is the GPU stack alive?": a version string
 *  and a self-test that touches Vulkan, the shader bundle and the baked
 *  resources, and reports what it found as JSON.
 *
 *  Nothing here keeps state. The engine handle is created, probed and
 *  destroyed inside spk_mobile_probe; the Dart side creates the long-lived
 *  one through spk_engine_create once it knows the device works.
 */
#include <spektrafilm/spk_engine.h>
#include <volk.h>

#include "io/raw_decoder.hpp"
#include "json.hpp"

#include "libraw/libraw.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

// Opaque to Dart: the isolates pass these pointers around as integers, and
// only the accessors below touch what they point at. The session owns the
// engine, so one release frees both.
struct spk_mobile_session {
    spk_engine* engine = nullptr;
    spk_session* session = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    // `spk_mobile_open_raw` creates its own engine for the one-shot path, so
    // releasing that session must also release the engine. The long-lived
    // editor opens a session *on* an engine it owns (`spk_mobile_open_raw_on`)
    // and destroys the engine itself.
    bool owns_engine = false;
};

struct spk_mobile_frame {
    std::vector<uint8_t> rgba8;
    uint32_t width = 0;
    uint32_t height = 0;
};

double elapsed_ms(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

// A box filter over the linear ProPhoto RGB source. `spk_max_plane_bytes`
// leaves the downscale to the caller because only the caller knows what it
// wants to do with the discarded pixels. A 24 MP ARW is 290 MB at 12 B/px and
// will not bind on a 128 MiB phone; the source has to shrink before `spk_open`.
void downscale_rgb(const std::vector<float>& src, uint32_t sw, uint32_t sh,
                   uint32_t dw, uint32_t dh, std::vector<float>& dst) {
    dst.assign(static_cast<size_t>(dw) * dh * 3, 0.0f);
    for (uint32_t y = 0; y < dh; ++y) {
        const uint32_t y0 = static_cast<uint32_t>(static_cast<uint64_t>(y) * sh / dh);
        const uint32_t y1 = std::max(
            y0 + 1u, static_cast<uint32_t>(static_cast<uint64_t>(y + 1) * sh / dh));
        for (uint32_t x = 0; x < dw; ++x) {
            const uint32_t x0 = static_cast<uint32_t>(static_cast<uint64_t>(x) * sw / dw);
            const uint32_t x1 = std::max(
                x0 + 1u, static_cast<uint32_t>(static_cast<uint64_t>(x + 1) * sw / dw));
            double r = 0.0, g = 0.0, b = 0.0;
            uint32_t count = 0;
            for (uint32_t yy = y0; yy < y1; ++yy) {
                const float* row = src.data() + (static_cast<size_t>(yy) * sw + x0) * 3;
                for (uint32_t xx = x0; xx < x1; ++xx) {
                    r += row[0];
                    g += row[1];
                    b += row[2];
                    row += 3;
                    ++count;
                }
            }
            float* out = dst.data() + (static_cast<size_t>(y) * dw + x) * 3;
            out[0] = static_cast<float>(r / count);
            out[1] = static_cast<float>(g / count);
            out[2] = static_cast<float>(b / count);
        }
    }
}

std::string escape(const char* text) {
    std::string out;
    if (text == nullptr) return out;
    for (const char* p = text; *p != '\0'; ++p) {
        const unsigned char c = static_cast<unsigned char>(*p);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::string version_string(uint32_t version) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u.%u.%u", VK_VERSION_MAJOR(version),
                  VK_VERSION_MINOR(version), VK_VERSION_PATCH(version));
    return buf;
}

const char* device_type_name(VkPhysicalDeviceType type) {
    switch (type) {
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated";
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete";
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual";
        case VK_PHYSICAL_DEVICE_TYPE_CPU: return "cpu";
        default: return "other";
    }
}

// Opens the loader (volk dlopen's libvulkan.so on Android), enumerates the
// physical devices and reports the one the engine would pick: the first with a
// compute queue. Returns a JSON object; never throws.
std::string vulkan_probe() {
    std::string j = "{";
    auto add = [&j](const std::string& field) {
        if (j.size() > 1) j += ',';
        j += field;
    };
    auto fail = [&add](const char* message) {
        add("\"ok\":false");
        add("\"error\":\"" + escape(message) + "\"");
    };

    const VkResult loaded = volkInitialize();
    if (loaded != VK_SUCCESS) {
        fail("volkInitialize failed: no libvulkan.so");
        j += '}';
        return j;
    }
    add("\"loader\":\"ok\"");

    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "spektrafilm-mobile";
    app.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;

    VkInstance instance = VK_NULL_HANDLE;
    const VkResult created = vkCreateInstance(&info, nullptr, &instance);
    if (created != VK_SUCCESS) {
        add("\"ok\":false");
        add("\"error\":\"vkCreateInstance failed (" + std::to_string(created) + ")\"");
        j += '}';
        return j;
    }
    // volkInitialize only resolves vkGetInstanceProcAddr/vkCreateInstance.
    // Every other instance-level entry point is null until this runs; without
    // it the next vkEnumeratePhysicalDevices call jumps to address 0.
    volkLoadInstance(instance);

    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance, &count, nullptr);
    if (count == 0) {
        fail("no Vulkan physical device");
        vkDestroyInstance(instance, nullptr);
        j += '}';
        return j;
    }

    VkPhysicalDevice devices[8]{};
    if (count > 8) count = 8;
    vkEnumeratePhysicalDevices(instance, &count, devices);

    bool found_compute = false;
    for (uint32_t d = 0; d < count && !found_compute; ++d) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(devices[d], &props);

        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, nullptr);
        std::vector<VkQueueFamilyProperties> family(families);
        if (families > 0) {
            vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, family.data());
        }
        bool compute = false;
        for (const VkQueueFamilyProperties& q : family) {
            if ((q.queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
                compute = true;
                break;
            }
        }
        if (!compute) continue;

        add("\"ok\":true");
        add("\"device\":\"" + escape(props.deviceName) + "\"");
        add("\"api\":\"" + version_string(props.apiVersion) + "\"");
        add("\"driver\":\"" + version_string(props.driverVersion) + "\"");
        add("\"vendor\":\"" + std::to_string(props.vendorID) + "\"");
        add("\"device_type\":\"" + std::string(device_type_name(props.deviceType)) + "\"");
        add("\"max_dimension_2d\":" + std::to_string(props.limits.maxImageDimension2D));
        add("\"max_storage_buffer_range\":" +
            std::to_string(static_cast<unsigned long long>(
                props.limits.maxStorageBufferRange)));
        add("\"device_count\":" + std::to_string(count));
        found_compute = true;
    }

    if (!found_compute) fail("no Vulkan device with a compute queue");

    vkDestroyInstance(instance, nullptr);
    j += '}';
    return j;
}

// Creates the real engine against the extracted resource directory. This
// exercises the math probe, the SPIR-V load and the baked profile parse, which
// is the whole stack a render needs.
std::string engine_probe(const char* resources_dir) {
    std::string j = "{";
    auto add = [&j](const std::string& field) {
        if (j.size() > 1) j += ',';
        j += field;
    };

    if (resources_dir == nullptr || *resources_dir == '\0') {
        add("\"ok\":false");
        add("\"error\":\"no resource directory\"");
        j += '}';
        return j;
    }

    spk_engine* engine = spk_engine_create(resources_dir, nullptr);
    if (engine == nullptr) {
        add("\"ok\":false");
        add("\"error\":\"" + escape(spk_last_error(nullptr)) + "\"");
        j += '}';
        return j;
    }

    add("\"ok\":true");
    const char* capabilities = spk_capabilities(engine);
    add("\"capabilities\":" + std::string(capabilities != nullptr ? capabilities : "null"));
    spk_engine_destroy(engine);
    j += '}';
    return j;
}

char* copy_to_c(const std::string& text) {
    char* out = static_cast<char*>(std::malloc(text.size() + 1));
    if (out != nullptr) std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

// The `{"ok":false,...}` reply every entry point returns on failure. Call
// sites write `fail_reply(...); return nullptr;`.
void fail_reply(char** out_json, const char* stage, const std::string& message) {
    spk::Json reply = spk::Json::object();
    reply.set("ok", spk::Json(false));
    reply.set("stage", spk::Json(std::string(stage)));
    reply.set("error", spk::Json(message));
    if (out_json != nullptr) *out_json = copy_to_c(reply.dump());
}

}  // namespace

extern "C" {

// Bumped whenever this shim's ABI changes; the Dart side asserts on it.
int32_t spk_mobile_abi_version(void) { return 4; }

const char* spk_mobile_build_info(void) { return spk_build_info(); }

// JSON: {"build":...,"vulkan":{...},"engine":{...}}
// Caller owns the string; release with spk_mobile_string_free.
char* spk_mobile_probe(const char* resources_dir) {
    std::string out = "{";
    out += "\"build\":\"" + escape(spk_build_info()) + "\",";
    out += "\"vulkan\":" + vulkan_probe() + ",";
    out += "\"engine\":" + engine_probe(resources_dir);
    out += '}';
    return copy_to_c(out);
}

void spk_mobile_string_free(char* text) { std::free(text); }

// --- RAW: decode once, render many tiers -------------------------------
//
// The sequence is the engine's own (engine/tools/raw_render.cpp): LibRaw
// compatible16 -> linear ProPhoto float32 -> spk_open -> spk_render -> RGBA16.
// The only thing this adds is the hand-off to Dart: sRGB output (so no colour
// management is needed on the Flutter side) and an 8-bit copy that
// ui.Image can take directly.
//
// `params_json` is the engine's delta and may be NULL or "{}". The five IO
// fields below are forced, because the decoded pixels are linear ProPhoto and
// the phone has no ColorSync: a caller asking for anything else would get a
// picture in a space nobody asked for.
// Creates the engine once for an editing session. The expensive part of
// `spk_engine_create` is parsing the baked profiles and uploading the shader
// bundle, so the editor must not do this per frame.
spk_engine* spk_mobile_engine_create(const char* resources_dir, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (resources_dir == nullptr || *resources_dir == '\0') {
        fail_reply(out_json, "arguments", "resources_dir is empty");
        return nullptr;
    }
    spk_engine* engine = spk_engine_create(resources_dir, nullptr);
    if (engine == nullptr) {
        const char* message = spk_last_error(nullptr);
        fail_reply(out_json, "engine", message != nullptr ? message : "spk_engine_create failed");
        return nullptr;
    }
    spk::Json reply = spk::Json::object();
    reply.set("ok", spk::Json(true));
    reply.set("max_plane_bytes", spk::Json(double(spk_max_plane_bytes(engine))));
    if (out_json != nullptr) *out_json = copy_to_c(reply.dump());
    return engine;
}

void spk_mobile_engine_destroy(spk_engine* engine) {
    if (engine != nullptr) spk_engine_destroy(engine);
}

// The engine's own capabilities JSON, read from the live engine instead of
// creating a second one just to ask.
int32_t spk_mobile_engine_capabilities(spk_engine* engine, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (engine == nullptr) {
        fail_reply(out_json, "arguments", "engine is null");
        return SPK_ERR_INVALID_ARG;
    }
    const char* capabilities = spk_capabilities(engine);
    if (out_json != nullptr) {
        *out_json = copy_to_c(capabilities != nullptr ? capabilities : "{}");
    }
    return SPK_OK;
}

// Pays the fixed per-stock-pair setup before the user is looking at it. It is
// idempotent -- warming a pair already warm costs a lookup -- and touches no
// session, so it is safe to run while the picker is up.
int32_t spk_mobile_engine_warm_up(spk_engine* engine, const char* film_stock,
                                  const char* print_stock, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (engine == nullptr) {
        fail_reply(out_json, "arguments", "engine is null");
        return SPK_ERR_INVALID_ARG;
    }
    char* reply = nullptr;
    const spk_status status =
        spk_warm_up(engine, film_stock, print_stock, &reply);
    if (status == SPK_OK) {
        if (out_json != nullptr) {
            *out_json = reply;
        } else if (reply != nullptr) {
            spk_string_free(reply);
        }
    } else {
        if (reply != nullptr) spk_string_free(reply);
        fail_reply(out_json, "warm_up", spk_last_error(engine));
    }
    return static_cast<int32_t>(status);
}

// Writes the camera's own JPEG preview beside an import, so the home grid can
// show a tile without paying for a decode. LibRaw exposes it as `unpack_thumb`:
// the bytes are already a JPEG, so this is a header read plus a file write
// (tens of milliseconds), not a render.
//
// Returns 1 when a preview was written, 0 when the file has none, -1 on error.
int32_t spk_mobile_write_thumbnail(const char* src_path, const char* out_path, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (src_path == nullptr || *src_path == '\0' || out_path == nullptr || *out_path == '\0') {
        fail_reply(out_json, "arguments", "src_path and out_path are required");
        return SPK_ERR_INVALID_ARG;
    }
    LibRaw raw;
    if (raw.open_file(src_path) != LIBRAW_SUCCESS) {
        fail_reply(out_json, "thumbnail", "LibRaw cannot open the file");
        return -1;
    }
    if (raw.unpack_thumb() != LIBRAW_SUCCESS) {
        // Many cameras ship no preview at all; that is not an error worth a
        // dialog, the tile just draws its placeholder.
        return 0;
    }
    const auto& thumb = raw.imgdata.thumbnail;
    if (thumb.tformat != LIBRAW_THUMBNAIL_JPEG || thumb.thumb == nullptr || thumb.tlength <= 0) {
        return 0;
    }
    FILE* out = std::fopen(out_path, "wb");
    if (out == nullptr) {
        fail_reply(out_json, "thumbnail", "cannot write the thumbnail");
        return -1;
    }
    const size_t written = std::fwrite(thumb.thumb, 1, size_t(thumb.tlength), out);
    std::fclose(out);
    if (written != size_t(thumb.tlength)) {
        std::remove(out_path);
        fail_reply(out_json, "thumbnail", "short write");
        return -1;
    }
    if (out_json != nullptr) {
        spk::Json reply;
        reply.set("ok", spk::Json(true));
        reply.set("bytes", spk::Json(double(written)));
        *out_json = copy_to_c(reply.dump());
    }
    return 1;
}

// The largest frame the device can bind, in pixels.
//
// `spk_max_plane_bytes` is the device's own limit and the source is already
// downscaled to it at open. The overscan canvas is a *second* allocation at
// 12 B/px and is bigger than the frame (the rebate and the film's width are
// laid around it), so a frame that fits can still produce a canvas that does
// not -- `spk_overscan_add_mask` then fails with "buffer argument 3 needs
// 181.9 MiB, this device allows 128.0 MiB". Exposing the budget lets the UI
// pick a tier size that the canvas fits inside, instead of discovering it by
// failing.
uint64_t spk_mobile_max_plane_pixels(spk_engine* engine) {
    if (engine == nullptr) return 0;
    const uint64_t bytes = spk_max_plane_bytes(engine);
    if (bytes == 0) return 0;
    // The same 5% headroom `fit_to_max_plane` keeps for row padding and the
    // intermediates the pipeline holds beside the plane.
    return static_cast<uint64_t>(static_cast<double>(bytes) * 0.95 / 12.0);
}

// Opens a RAW on an existing engine. This is the editor's entry point: the
// engine stays alive for the whole session, so `spk_set_params` + `spk_reprint`
// can turn a slider into a new frame instead of a full engine restart.
// Shrinks a linear RGB buffer in place until it fits the device's largest
// bindable plane. Both open paths need this: a 24 MP ARW is 290 MB at 12 B/px,
// and a 12 MP phone JPEG is 144 MB, neither of which binds on a small device.
static void fit_to_max_plane(spk_engine* engine, std::vector<float>& rgb,
                             uint32_t& width, uint32_t& height,
                             uint64_t& max_pixels, bool& downscaled,
                             double& downscale_ms) {
    max_pixels = 0;
    downscaled = false;
    downscale_ms = 0.0;

    const uint64_t max_plane = spk_max_plane_bytes(engine);
    if (max_plane == 0) return;

    // 5% headroom: rows are padded to the device's linear alignment and the
    // pipeline keeps intermediates alongside the source plane.
    max_pixels = static_cast<uint64_t>(static_cast<double>(max_plane) * 0.95 / 12.0);
    const uint64_t source_pixels = static_cast<uint64_t>(width) * height;
    if (source_pixels <= max_pixels) return;

    const double factor = std::sqrt(
        static_cast<double>(max_pixels) / static_cast<double>(source_pixels));
    uint32_t target_w = std::max(
        1u, static_cast<uint32_t>(std::floor(width * factor)));
    uint32_t target_h = std::max(
        1u, static_cast<uint32_t>(std::floor(height * factor)));
    while (static_cast<uint64_t>(target_w) * target_h > max_pixels) {
        if (target_w > target_h) --target_w; else --target_h;
    }

    const auto scale_start = Clock::now();
    std::vector<float> scaled;
    downscale_rgb(rgb, width, height, target_w, target_h, scaled);
    rgb.swap(scaled);
    width = target_w;
    height = target_h;
    downscaled = true;
    downscale_ms = elapsed_ms(scale_start);
}

spk_mobile_session* spk_mobile_open_raw_on(spk_engine* engine, const char* raw_path,
                                           const char* params_json, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (engine == nullptr) {
            fail_reply(out_json, "arguments", "engine is null");
            return nullptr;
        }
        if (raw_path == nullptr || *raw_path == '\0') {
            fail_reply(out_json, "arguments", "raw_path is empty");
            return nullptr;
        }

        const double engine_ms = 0.0;
        auto t = Clock::now();

        spk::Json params = spk::Json::object();
        if (params_json != nullptr && *params_json != '\0') {
            std::string parse_error;
            if (!spk::Json::parse(params_json, params, parse_error)) {
                fail_reply(out_json, "params", parse_error);
                return nullptr;
            }
            if (!params.is_object()) {
                fail_reply(out_json, "params", "params_json must be a JSON object");
                return nullptr;
            }
        }
        params.set("input_color_space", spk::Json(std::string("ProPhoto RGB")));
        params.set("input_cctf_decoding", spk::Json(false));
        params.set("output_color_space", spk::Json(std::string("sRGB")));
        params.set("output_cctf_encoding", spk::Json(true));
        params.set("extended_dynamic_range", spk::Json(false));

        spk::io::DecodedRaw decoded;
        std::string error;
        t = Clock::now();
        if (!spk::io::decode_raw_compatible(raw_path, decoded, error)) {
            fail_reply(out_json, "decode", error);
            return nullptr;
        }
        const double decode_ms = elapsed_ms(t);
        const uint32_t source_width = decoded.width;
        const uint32_t source_height = decoded.height;
        uint32_t width = source_width;
        uint32_t height = source_height;
        uint64_t max_pixels = 0;
        bool downscaled = false;
        double downscale_ms = 0.0;
        fit_to_max_plane(engine, decoded.rgb, width, height, max_pixels, downscaled,
                         downscale_ms);

        const spk::io::RawMetadata metadata = decoded.metadata;
        const spk::io::RawDecodeTimings decode_timings = decoded.timings;

        const std::string params_text = params.dump();
        spk_image input{decoded.rgb.data(), width, height, 3};
        char* open_reply = nullptr;
        t = Clock::now();
        spk_session* session = spk_open(engine, &input, params_text.c_str(), &open_reply);
        const double open_ms = elapsed_ms(t);
        if (session == nullptr) {
            const std::string message = spk_last_error(engine);
            if (open_reply != nullptr) spk_string_free(open_reply);
            fail_reply(out_json, "open", message);
            return nullptr;
        }
        // The session owns its copy of the source now; give back ~290 MB at
        // 24 MP before the first render asks the pool for negatives.
        std::vector<float>().swap(decoded.rgb);

        spk::Json reply = spk::Json::object();
        reply.set("ok", spk::Json(true));
        reply.set("max_plane_bytes", spk::Json(double(spk_max_plane_bytes(engine))));

        spk::Json in = spk::Json::object();
        in.set("path", spk::Json(std::string(raw_path)));
        in.set("source_width", spk::Json(double(source_width)));
        in.set("source_height", spk::Json(double(source_height)));
        in.set("width", spk::Json(double(width)));
        in.set("height", spk::Json(double(height)));
        in.set("downscaled", spk::Json(downscaled));
        in.set("max_pixels", spk::Json(double(max_pixels)));
        in.set("make", spk::Json(metadata.make));
        in.set("model", spk::Json(metadata.model));
        in.set("color_space", spk::Json(std::string("ProPhoto RGB")));
        in.set("transfer", spk::Json(std::string("linear")));
        reply.set("input", std::move(in));

        spk::Json decode = spk::Json::object();
        decode.set("mode", spk::Json(std::string("compatible16")));
        decode.set("libraw", spk::Json(metadata.libraw_version));
        decode.set("decoder", spk::Json(metadata.decoder_name));
        decode.set("openmp", spk::Json(decode_timings.openmp_enabled));
        decode.set("workers", spk::Json(double(decode_timings.workers)));
        decode.set("open_ms", spk::Json(decode_timings.open_ms));
        decode.set("unpack_ms", spk::Json(decode_timings.unpack_ms));
        decode.set("process_ms", spk::Json(decode_timings.process_ms));
        decode.set("convert_ms", spk::Json(decode_timings.convert_ms));
        reply.set("decode", std::move(decode));

        spk::Json open_value;
        std::string reply_error;
        if (open_reply != nullptr && spk::Json::parse(open_reply, open_value, reply_error)) {
            reply.set("open", std::move(open_value));
        }
        if (open_reply != nullptr) spk_string_free(open_reply);

        reply.set("engine_ms", spk::Json(engine_ms));
        reply.set("decode_ms", spk::Json(decode_ms));
        reply.set("downscale_ms", spk::Json(downscale_ms));
        reply.set("open_ms", spk::Json(open_ms));
        if (out_json != nullptr) *out_json = copy_to_c(reply.dump());

        return new spk_mobile_session{engine, session, width, height, /*owns_engine=*/false};
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_open_raw_on");
        return nullptr;
    }
}

// Opens a session on pixels the app decoded itself (a JPEG from the gallery,
// say). LibRaw is skipped entirely: `spk_open` already takes a linear RGB
// buffer, so the only contract is that the caller hands over linear
// **ProPhoto RGB** float32, which is what Dart converts sRGB JPEGs into.
spk_mobile_session* spk_mobile_open_image_on(spk_engine* engine, const float* rgb,
                                             uint32_t width, uint32_t height,
                                             const char* params_json, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (engine == nullptr) {
            fail_reply(out_json, "arguments", "engine is null");
            return nullptr;
        }
        if (rgb == nullptr || width == 0 || height == 0) {
            fail_reply(out_json, "arguments", "image buffer is empty");
            return nullptr;
        }

        spk::Json params = spk::Json::object();
        if (params_json != nullptr && *params_json != '\0') {
            std::string parse_error;
            if (!spk::Json::parse(params_json, params, parse_error)) {
                fail_reply(out_json, "params", parse_error);
                return nullptr;
            }
            if (!params.is_object()) {
                fail_reply(out_json, "params", "params_json must be a JSON object");
                return nullptr;
            }
        }
        params.set("input_color_space", spk::Json(std::string("ProPhoto RGB")));
        params.set("input_cctf_decoding", spk::Json(false));
        params.set("output_color_space", spk::Json(std::string("sRGB")));
        params.set("output_cctf_encoding", spk::Json(true));
        params.set("extended_dynamic_range", spk::Json(false));

        auto t = Clock::now();
        const uint32_t source_width = width;
        const uint32_t source_height = height;
        const size_t floats = static_cast<size_t>(width) * height * 3;
        std::vector<float> pixels(rgb, rgb + floats);
        uint64_t max_pixels = 0;
        bool downscaled = false;
        double downscale_ms = 0.0;
        fit_to_max_plane(engine, pixels, width, height, max_pixels, downscaled,
                         downscale_ms);

        const std::string params_text = params.dump();
        spk_image input{pixels.data(), width, height, 3};
        char* open_reply = nullptr;
        t = Clock::now();
        spk_session* session = spk_open(engine, &input, params_text.c_str(), &open_reply);
        const double open_ms = elapsed_ms(t);
        if (session == nullptr) {
            const std::string message = spk_last_error(engine);
            if (open_reply != nullptr) spk_string_free(open_reply);
            fail_reply(out_json, "open", message);
            return nullptr;
        }
        std::vector<float>().swap(pixels);

        spk::Json reply = spk::Json::object();
        reply.set("ok", spk::Json(true));
        reply.set("max_plane_bytes", spk::Json(double(spk_max_plane_bytes(engine))));

        spk::Json in = spk::Json::object();
        in.set("path", spk::Json(std::string()));
        in.set("source", spk::Json(std::string("photo")));
        in.set("source_width", spk::Json(double(source_width)));
        in.set("source_height", spk::Json(double(source_height)));
        in.set("width", spk::Json(double(width)));
        in.set("height", spk::Json(double(height)));
        in.set("downscaled", spk::Json(downscaled));
        in.set("max_pixels", spk::Json(double(max_pixels)));
        in.set("make", spk::Json(std::string()));
        in.set("model", spk::Json(std::string()));
        in.set("color_space", spk::Json(std::string("ProPhoto RGB")));
        in.set("transfer", spk::Json(std::string("linear")));
        reply.set("input", std::move(in));

        spk::Json decode = spk::Json::object();
        decode.set("mode", spk::Json(std::string("dart-srgb8")));
        decode.set("libraw", spk::Json(std::string()));
        decode.set("decoder", spk::Json(std::string("dart image")));
        reply.set("decode", std::move(decode));

        spk::Json open_value;
        std::string reply_error;
        if (open_reply != nullptr && spk::Json::parse(open_reply, open_value, reply_error)) {
            reply.set("open", std::move(open_value));
        }
        if (open_reply != nullptr) spk_string_free(open_reply);

        reply.set("engine_ms", spk::Json(0.0));
        reply.set("decode_ms", spk::Json(0.0));
        reply.set("downscale_ms", spk::Json(downscale_ms));
        reply.set("open_ms", spk::Json(open_ms));
        if (out_json != nullptr) *out_json = copy_to_c(reply.dump());

        return new spk_mobile_session{engine, session, width, height, /*owns_engine=*/false};
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_open_image_on");
        return nullptr;
    }
}

// The one-shot entry point kept for the probe page: creates its own engine,
// opens the RAW, and lets the session own both.
spk_mobile_session* spk_mobile_open_raw(const char* resources_dir, const char* raw_path,
                                        const char* params_json, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    char* engine_reply = nullptr;
    spk_engine* engine = spk_mobile_engine_create(resources_dir, &engine_reply);
    if (engine == nullptr) {
        if (out_json != nullptr) {
            *out_json = engine_reply;
        } else if (engine_reply != nullptr) {
            spk_mobile_string_free(engine_reply);
        }
        return nullptr;
    }
    spk_mobile_session* session = spk_mobile_open_raw_on(engine, raw_path, params_json, out_json);
    if (session == nullptr) {
        spk_engine_destroy(engine);
        return nullptr;
    }
    session->owns_engine = true;
    return session;
}

// Renders one tier and converts the engine's RGBA16 into tightly packed
// RGBA8. The engine has already encoded sRGB and bounded the values, so this
// is a rounding, not a tone map: 16-bit code -> 8-bit code is (v + 128) / 257.
//
// `row_stride_px` counts **pixels**, and each pixel is 4 uint16, so a row
// advances by `row_stride_px * 4` elements. Using the stride alone reads 1/4
// of each row and repeats it -- the bug the reference Android port documents.
// Shared tail of every render path: RGBA16 -> tightly packed RGBA8, plus the
// timing/flag reply. `render_ms` is the wall time of the engine call; the
// caller measures it so `export_source` can report 0 without lying about a
// render that never happened.
//
// `linear_source` is true only for `spk_export_source`: its pixels are working
// space with no transfer function, so they need an sRGB encode before Flutter
// shows them. A rendered print already carries the engine's sRGB encoding.
static spk_mobile_frame* frame_from_result(spk_result& result, const char* tier_name,
                                           double render_ms, bool linear_source,
                                           char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (result.rgba16 == nullptr || result.width == 0 || result.height == 0) {
        spk_result_free(&result);
        fail_reply(out_json, "render", "the engine returned no pixels");
        return nullptr;
    }

    auto encode = [linear_source](uint16_t value) {
        double x = static_cast<double>(value) / 65535.0;
        if (!linear_source) return static_cast<uint8_t>((value + 128u) / 257u);
        x = std::min(1.0, std::max(0.0, x));
        const double encoded =
            x <= 0.0031308 ? 12.92 * x : 1.055 * std::pow(x, 1.0 / 2.4) - 0.055;
        return static_cast<uint8_t>(std::lround(encoded * 255.0));
    };

    auto frame = std::make_unique<spk_mobile_frame>();
    frame->width = result.width;
    frame->height = result.height;
    frame->rgba8.resize(static_cast<size_t>(result.width) * result.height * 4);
    const auto t = Clock::now();
    uint8_t* dst = frame->rgba8.data();
    for (uint32_t y = 0; y < result.height; ++y) {
        const uint16_t* row = result.rgba16 +
                              static_cast<size_t>(y) * result.row_stride_px * 4;
        for (uint32_t x = 0; x < result.width; ++x) {
            const uint16_t* p = row + static_cast<size_t>(x) * 4;
            *dst++ = encode(p[0]);
            *dst++ = encode(p[1]);
            *dst++ = encode(p[2]);
            *dst++ = 255;
        }
    }
    const double convert_ms = elapsed_ms(t);

    spk::Json reply = spk::Json::object();
    reply.set("ok", spk::Json(true));
    reply.set("tier", spk::Json(std::string(tier_name)));
    reply.set("width", spk::Json(double(result.width)));
    reply.set("height", spk::Json(double(result.height)));
    reply.set("render_ms", spk::Json(render_ms));
    reply.set("engine_ms", spk::Json(result.elapsed_ms));
    reply.set("convert_ms", spk::Json(convert_ms));
    reply.set("reprint", spk::Json(result.reprint != 0));
    reply.set("negative_cached", spk::Json(result.negative_was_cached != 0));
    spk_result_free(&result);

    if (out_json != nullptr) *out_json = copy_to_c(reply.dump());
    return frame.release();
}

spk_mobile_frame* spk_mobile_session_render(spk_mobile_session* handle, const char* tier,
                                            char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (handle == nullptr || handle->session == nullptr) {
            fail_reply(out_json, "arguments", "session is null");
            return nullptr;
        }
        const std::string tier_name = (tier != nullptr && *tier != '\0') ? tier : "preview";

        spk_result result{};
        const auto t = Clock::now();
        const spk_status status = spk_render(handle->session, tier_name.c_str(), &result);
        const double render_ms = elapsed_ms(t);
        if (status != SPK_OK) {
            spk_result_free(&result);
            fail_reply(out_json, "render", spk_last_error(handle->engine));
            return nullptr;
        }
        return frame_from_result(result, tier_name.c_str(), render_ms, /*linear_source=*/false, out_json);
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_session_render");
        return nullptr;
    }
}

// The live path. `spk_reprint` reuses the cached negative and only runs the
// print chain; when there is no cached negative (first frame, or a shoot-layer
// parameter just invalidated it) it runs the film side itself. That makes it
// the only call an editor needs for a slider: no special-casing.
spk_mobile_frame* spk_mobile_session_reprint(spk_mobile_session* handle, const char* tier,
                                             char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (handle == nullptr || handle->session == nullptr) {
            fail_reply(out_json, "arguments", "session is null");
            return nullptr;
        }
        const std::string tier_name = (tier != nullptr && *tier != '\0') ? tier : "live";

        spk_result result{};
        const auto t = Clock::now();
        const spk_status status = spk_reprint(handle->session, tier_name.c_str(), &result);
        const double render_ms = elapsed_ms(t);
        if (status != SPK_OK) {
            spk_result_free(&result);
            fail_reply(out_json, "reprint", spk_last_error(handle->engine));
            return nullptr;
        }
        return frame_from_result(result, tier_name.c_str(), render_ms, /*linear_source=*/false, out_json);
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_session_reprint");
        return nullptr;
    }
}

// The "before" side of a comparison: the source before the film, no negative
// and no print touched.
// Which papers carry a shipped LUT, straight from print_luts.json.
char* spk_mobile_print_lut_catalog(spk_engine* engine) {
    if (engine == nullptr) return copy_to_c("{}");
    return copy_to_c(spk_print_lut_catalog(engine));
}

// Switch papers through the LUT instead of reprinting: 2 ms against 34 ms at
// the preview tier, because the cached negative is already there and the table
// is three vectors. The engine warns when the film is not the one the table
// was baked against; the caller decides whether that matters.
spk_mobile_frame* spk_mobile_session_preview_stock_lut(spk_mobile_session* handle,
                                                       const char* print_stock, const char* tier,
                                                       char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (handle == nullptr || handle->session == nullptr) {
            fail_reply(out_json, "arguments", "session is null");
            return nullptr;
        }
        if (print_stock == nullptr || *print_stock == '\0') {
            fail_reply(out_json, "arguments", "print_stock is required");
            return nullptr;
        }
        const std::string tier_name = (tier != nullptr && *tier != '\0') ? tier : "live";

        spk_result result{};
        const auto t = Clock::now();
        const spk_status status =
            spk_preview_stock_lut(handle->session, print_stock, tier_name.c_str(), &result, nullptr);
        const double render_ms = elapsed_ms(t);
        if (status != SPK_OK) {
            spk_result_free(&result);
            fail_reply(out_json, "lut", spk_last_error(handle->engine));
            return nullptr;
        }
        return frame_from_result(result, tier_name.c_str(), render_ms, /*linear_source=*/false, out_json);
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_session_preview_stock_lut");
        return nullptr;
    }
}

spk_mobile_frame* spk_mobile_session_export_source(spk_mobile_session* handle, const char* tier,
                                                   char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    try {
        if (handle == nullptr || handle->session == nullptr) {
            fail_reply(out_json, "arguments", "session is null");
            return nullptr;
        }
        const std::string tier_name = (tier != nullptr && *tier != '\0') ? tier : "live";

        spk_result result{};
        const spk_status status = spk_export_source(handle->session, tier_name.c_str(), &result);
        if (status != SPK_OK) {
            spk_result_free(&result);
            fail_reply(out_json, "source", spk_last_error(handle->engine));
            return nullptr;
        }
        return frame_from_result(result, tier_name.c_str(), 0.0, /*linear_source=*/true, out_json);
    } catch (const std::exception& e) {
        fail_reply(out_json, "internal", e.what());
        return nullptr;
    } catch (...) {
        fail_reply(out_json, "internal", "unknown failure in spk_mobile_session_export_source");
        return nullptr;
    }
}

// Live parameter change. `spk_set_params` reports what it invalidated in the
// reply; the editor reads that to decide between reprint and a full render.
// In practice it calls reprint either way: reprint falls back to the film side
// when the negative is gone.
int32_t spk_mobile_session_set_params(spk_mobile_session* handle, const char* delta_json,
                                      char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (handle == nullptr || handle->session == nullptr) {
        fail_reply(out_json, "arguments", "session is null");
        return SPK_ERR_INVALID_ARG;
    }
    char* reply = nullptr;
    const spk_status status = spk_set_params(handle->session, delta_json, &reply);
    if (status == SPK_OK) {
        if (out_json != nullptr) {
            *out_json = reply;
        } else if (reply != nullptr) {
            spk_string_free(reply);
        }
    } else {
        if (reply != nullptr) spk_string_free(reply);
        fail_reply(out_json, "params", spk_last_error(handle->engine));
    }
    return static_cast<int32_t>(status);
}

// RFC-023's scene latitude: measure, suggest and solve — it never renders.
// The reply's `fit.params_delta` is what the caller sends to
// `spk_set_params`; the resolved knees and rooms never travel outward, so a
// later paper change cannot re-solve an old edit.
int32_t spk_mobile_session_scene_latitude(spk_mobile_session* handle, const char* request_json,
                                          char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (handle == nullptr || handle->session == nullptr) {
        fail_reply(out_json, "arguments", "session is null");
        return SPK_ERR_INVALID_ARG;
    }
    char* reply = nullptr;
    const spk_status status = spk_scene_latitude(handle->session, request_json, &reply);
    if (status == SPK_OK) {
        if (out_json != nullptr) {
            *out_json = reply;
        } else if (reply != nullptr) {
            spk_string_free(reply);
        }
    } else {
        if (reply != nullptr) spk_string_free(reply);
        fail_reply(out_json, "latitude", spk_last_error(handle->engine));
    }
    return static_cast<int32_t>(status);
}

int32_t spk_mobile_session_solve(spk_mobile_session* handle, const char* target,
                                 char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (handle == nullptr || handle->session == nullptr) {
        fail_reply(out_json, "arguments", "session is null");
        return SPK_ERR_INVALID_ARG;
    }
    char* reply = nullptr;
    const spk_status status = spk_solve(handle->session, target, &reply);
    if (status == SPK_OK) {
        if (out_json != nullptr) {
            *out_json = reply;
        } else if (reply != nullptr) {
            spk_string_free(reply);
        }
    } else {
        if (reply != nullptr) spk_string_free(reply);
        fail_reply(out_json, "solve", spk_last_error(handle->engine));
    }
    return static_cast<int32_t>(status);
}

int32_t spk_mobile_session_get_params(spk_mobile_session* handle, char** out_json) {
    if (out_json != nullptr) *out_json = nullptr;
    if (handle == nullptr || handle->session == nullptr) {
        fail_reply(out_json, "arguments", "session is null");
        return SPK_ERR_INVALID_ARG;
    }
    char* reply = nullptr;
    const spk_status status = spk_get_params(handle->session, &reply);
    if (status == SPK_OK) {
        if (out_json != nullptr) {
            *out_json = reply;
        } else if (reply != nullptr) {
            spk_string_free(reply);
        }
    } else {
        if (reply != nullptr) spk_string_free(reply);
        fail_reply(out_json, "params", spk_last_error(handle->engine));
    }
    return static_cast<int32_t>(status);
}

const uint8_t* spk_mobile_frame_rgba8(const spk_mobile_frame* frame) {
    return frame != nullptr ? frame->rgba8.data() : nullptr;
}

uint32_t spk_mobile_frame_width(const spk_mobile_frame* frame) {
    return frame != nullptr ? frame->width : 0;
}

uint32_t spk_mobile_frame_height(const spk_mobile_frame* frame) {
    return frame != nullptr ? frame->height : 0;
}

void spk_mobile_frame_release(spk_mobile_frame* frame) { delete frame; }

void spk_mobile_session_release(spk_mobile_session* handle) {
    if (handle == nullptr) return;
    if (handle->session != nullptr) spk_session_release(handle->session);
    if (handle->engine != nullptr && handle->owns_engine) spk_engine_destroy(handle->engine);
    delete handle;
}

}  // extern "C"
