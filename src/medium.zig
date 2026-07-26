/// Parameters for the per-channel underwater image formation model.
/// Coefficients are attenuation rates in inverse metres; b_inf is the
/// asymptotic backscatter colour.
pub const Params = struct {
    beta_d: [3]f32,
    beta_b: [3]f32,
    b_inf: [3]f32,
};

/// Apply the underwater image formation model to an unattenuated albedo.
///
/// I = J * exp(-beta_d * z) + b_inf * (1 - exp(-beta_b * z))
///
/// This function performs no allocation or I/O.
pub fn apply(albedo: [3]f32, z: f32, p: Params) [3]f32 {
    if (z == 0.0) return albedo;

    var result: [3]f32 = undefined;
    for (0..3) |channel| {
        const transmission = @exp(-p.beta_d[channel] * z);
        const backscatter_transmission = @exp(-p.beta_b[channel] * z);
        result[channel] = albedo[channel] * transmission +
            p.b_inf[channel] * (1.0 - backscatter_transmission);
    }
    return result;
}
