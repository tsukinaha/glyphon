struct VertexInput {
    @builtin(vertex_index) vertex_idx: u32,
    @location(0) pos: vec2<i32>,
    @location(1) dim: u32,
    @location(2) uv: u32,
    @location(3) color: u32,
    @location(4) content_type_with_srgb: u32,
    @location(5) depth: f32,
    @location(6) shadow_radius: f32,
    @location(7) shadow_intensity: f32,
}

struct VertexOutput {
    @invariant @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) @interpolate(flat) content_type: u32,
    @location(3) shadow_radius: f32,
    @location(4) shadow_intensity: f32, 
};

struct Params {
    screen_resolution: vec2<u32>,
};

@group(0) @binding(0)
var color_atlas_texture: texture_2d<f32>;

@group(0) @binding(1)
var mask_atlas_texture: texture_2d<f32>;

@group(0) @binding(2)
var atlas_sampler: sampler;

@group(1) @binding(0)
var<uniform> params: Params;

fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

@vertex
fn vs_main(in_vert: VertexInput) -> VertexOutput {
    var pos = in_vert.pos;
    let width = in_vert.dim & 0xffffu;
    let height = (in_vert.dim & 0xffff0000u) >> 16u;
    let color = in_vert.color;
    var uv = vec2<u32>(in_vert.uv & 0xffffu, (in_vert.uv & 0xffff0000u) >> 16u);
    let v = in_vert.vertex_idx;

    let corner_position = vec2<u32>(
        in_vert.vertex_idx & 1u,
        (in_vert.vertex_idx >> 1u) & 1u,
    );

    let corner_offset = vec2<u32>(width, height) * corner_position;

    uv = uv + corner_offset;
    pos = pos + vec2<i32>(corner_offset);

    var vert_output: VertexOutput;

    vert_output.position = vec4<f32>(
        2.0 * vec2<f32>(pos) / vec2<f32>(params.screen_resolution) - 1.0,
        in_vert.depth,
        1.0,
    );

    vert_output.position.y *= -1.0;

    let content_type = in_vert.content_type_with_srgb & 0xffffu;
    let srgb = (in_vert.content_type_with_srgb & 0xffff0000u) >> 16u;

    switch srgb {
        case 0u: {
            vert_output.color = vec4<f32>(
                f32((color & 0x00ff0000u) >> 16u) / 255.0,
                f32((color & 0x0000ff00u) >> 8u) / 255.0,
                f32(color & 0x000000ffu) / 255.0,
                f32((color & 0xff000000u) >> 24u) / 255.0,
            );
        }
        case 1u: {
            vert_output.color = vec4<f32>(
                srgb_to_linear(f32((color & 0x00ff0000u) >> 16u) / 255.0),
                srgb_to_linear(f32((color & 0x0000ff00u) >> 8u) / 255.0),
                srgb_to_linear(f32(color & 0x000000ffu) / 255.0),
                f32((color & 0xff000000u) >> 24u) / 255.0,
            );
        }
        default: {}
    }

    var dim: vec2<u32> = vec2(0u);
    switch content_type {
        case 0u: {
            dim = textureDimensions(color_atlas_texture);
            break;
        }
        case 1u: {
            dim = textureDimensions(mask_atlas_texture);
            break;
        }
        default: {}
    }

    vert_output.content_type = content_type;

    vert_output.uv = vec2<f32>(uv) / vec2<f32>(dim);

    vert_output.shadow_radius = in_vert.shadow_radius;
    vert_output.shadow_intensity = in_vert.shadow_intensity;

    return vert_output;
}

@fragment
fn fs_main(in_frag: VertexOutput) -> @location(0) vec4<f32> {
    switch in_frag.content_type {
        case 0u: {
            return textureSampleLevel(color_atlas_texture, atlas_sampler, in_frag.uv, 0.0);
        }
        case 1u: {
            let glyph_alpha = textureSampleLevel(mask_atlas_texture, atlas_sampler, in_frag.uv, 0.0).x;

            var max_shadow_value = 0.0;

            let MAX_KERNEL_RADIUS = 5.0;
            let radius_pixels = in_frag.shadow_radius;
            let shadow_rgb = vec3<f32>(0.0, 0.0, 0.0);

            if (radius_pixels > 0.0) {
                let tex_dims = vec2<f32>(textureDimensions(mask_atlas_texture, 0u));
                let pixel_size = vec2<f32>(1.0 / tex_dims.x, 1.0 / tex_dims.y);

                let R_int = i32(min(ceil(radius_pixels), MAX_KERNEL_RADIUS));

                for (var dy: i32 = -R_int; dy <= R_int; dy = dy + 1) {
                    for (var dx: i32 = -R_int; dx <= R_int; dx = dx + 1) {
                        let offset_pixels = vec2<f32>(f32(dx), f32(dy));
                        let dist_sq = dot(offset_pixels, offset_pixels);

                        if (dist_sq <= radius_pixels * radius_pixels) {
                            let dist_pixels = sqrt(dist_sq);
                            let sample_uv = in_frag.uv - offset_pixels * pixel_size;

                            let text_mask_at_P = textureSampleLevel(mask_atlas_texture, atlas_sampler, sample_uv, 0.0).x;

                            if (text_mask_at_P > 0.01) {
                                let falloff = smoothstep(radius_pixels, 0.0, dist_pixels);
                                let current_shadow_val = text_mask_at_P * in_frag.shadow_intensity * falloff;
                                max_shadow_value = max(max_shadow_value, current_shadow_val);
                            }
                        }
                    }
                }
            }

            let combined_shape_alpha = clamp(max(glyph_alpha, max_shadow_value), 0.0, 1.0);
            
            let final_rgb = mix(shadow_rgb, in_frag.color.rgb, glyph_alpha);
            
            let final_a = in_frag.color.a * combined_shape_alpha;
            
            return vec4<f32>(final_rgb, final_a);
        }
        default: {
            return vec4<f32>(0.0);
        }
    }
}
