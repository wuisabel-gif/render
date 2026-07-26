# Underwater image formation model

The splat path uses the following per-channel underwater image formation model:

\[
I = J\,\exp(-\beta_d z) + b_\infty\,(1 - \exp(-\beta_b z)).
\]

The first term is scene radiance/albedo attenuated along the viewing path. The
second term is water-light backscatter that approaches the water colour at large
range. This is the model written as Equation (3) in the SeaSplat paper [1].
It is a compact model of the direct and backscatter components; it is not a
complete optical simulation of every underwater effect.

The implementation applies the equation independently to the three renderer
colour channels. In code, `Params` stores `beta_d`, `beta_b`, and `b_inf`, and
`apply(albedo, z, params)` evaluates one RGB sample. At `z = 0`, the model
returns the input albedo: there is no attenuation and no accumulated
backscatter. The current single-file procedural CLI does not invoke this
function; it is the medium primitive for the splat path described below.

## Symbols and units

| Symbol | Renderer representation | Meaning | Units |
|---|---|---|---|
| `I` | `[3]f32` result | Observed underwater colour after the medium model | Normalized RGB / relative radiance (renderer units) |
| `J` | `[3]f32` `albedo` | Unattenuated scene colour that would be observed without the medium | Normalized RGB / relative radiance (renderer units) |
| `z` | `f32` `z` | Distance along the viewing ray from the sample to the camera | m |
| `beta_d` (`βᵈ`) | `[3]f32` `Params.beta_d` | Direct-path attenuation coefficient | m⁻¹ |
| `beta_b` (`βᵇ`) | `[3]f32` `Params.beta_b` | Backscatter accumulation coefficient | m⁻¹ |
| `b_inf` (`B∞`) | `[3]f32` `Params.b_inf` | Water/backscatter colour approached as range tends to infinity | Normalized RGB / relative radiance (renderer units) |
| `exp` | scalar exponential | Natural exponential function used for transmission | Dimensionless result |
| RGB channel | array index `0..2` | Independent red, green, and blue evaluation of each vector term | — |

The products `beta_d * z` and `beta_b * z` are dimensionless, as required by
`exp`. The renderer does not prescribe universal coefficient values: they are
scene- and water-dependent parameters that must come from calibration or a
specified experiment. Therefore this repository includes no asserted numeric
values, and there are no coefficient values here requiring a separate numeric
citation. The SeaSplat paper discusses estimating medium parameters from
underwater imagery [1]; the revised underwater image-formation work explains
why wavelength-dependent direct and backscatter attenuation matters [2].

## What this is and is not

**This is:**

- a dependency-free renderer for trained 3D Gaussian-splat (`.ply`) scene data;
- a reference CPU rendering path, with the medium equation applied to splat
  colours using view-ray distance; and
- a place for rendering and measurement tooling. Measurements must be produced
  by a documented, reproducible run; this repository records no benchmark,
  performance, or accuracy result.

**This is not:**

- a training, optimisation, camera-calibration, or COLMAP repository;
- a source of pretrained scenes or universal water coefficients; or
- a claim that the procedural sample image is a physically reconstructed pool.

Training and reconstruction happen in upstream research repositories, not in
this renderer. Relevant named projects include the original 3D Gaussian
Splatting implementation by GraphDeco/INRIA [3], and underwater extensions
such as SeaSplat [1] and Gaussian Splashing [4]. Those projects have their own
code, data, and licences; this repository only consumes compatible trained
scene output.

## Two rendering paths

The physical equation above applies to the **splat path**, where a Gaussian's
view-ray distance supplies `z`. The legacy RoboPool procedural scene is a
separate screen-space shader port. Its `turbidity` argument computes
`clamp01(uv.y * turbidity)` and blends toward a haze colour. That is a
non-physical screen-Y fade: `uv.y` is a normalized image coordinate, not a
metres-valued distance or per-pixel depth, and `turbidity` is not `beta_d` or
`beta_b`. It must not be interpreted as an estimate of underwater optical
coefficients.

## References

[1] D. Y. Yang et al., “SeaSplat: Representing Underwater Scenes with 3D
Gaussian Splatting and a Physically Grounded Image Formation Model,” arXiv:
2409.17345, Equation (3), 2024. [Paper](https://arxiv.org/abs/2409.17345),
[project page](https://seasplat.github.io/).

[2] C. Akkaynak and T. Treibitz, “A Revised Underwater Image Formation Model,”
CVPR 2018. [Paper (CVF open access)](https://openaccess.thecvf.com/content_cvpr_2018/papers/Akkaynak_A_Revised_Underwater_CVPR_2018_paper.pdf).

[3] B. Kerbl et al., “3D Gaussian Splatting for Real-Time Radiance Field
Rendering,” official reference implementation. [GraphDeco/INRIA repository](https://github.com/graphdeco-inria/gaussian-splatting).

[4] “Gaussian Splashing: Direct Volumetric Rendering Underwater and Complex
Scenes,” official implementation. [Repository](https://github.com/BGU-CS-VIL/gaussianSplashing).
