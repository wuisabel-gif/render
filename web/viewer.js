// Minimal WebGPU host for shader.wgsl. No framework or package manager is required.
const canvas = document.querySelector('#view');
const status = document.querySelector('#status');

const controls = ['bdR', 'bdG', 'bdB', 'bbR', 'bbG', 'bbB', 'biR', 'biG', 'biB'];
const valueOf = id => Number(document.querySelector(`#${id}`).value);
for (const id of controls) {
  const input = document.querySelector(`#${id}`);
  const output = document.querySelector(`#${id}Value`);
  const update = () => { output.value = Number(input.value).toFixed(2); };
  input.addEventListener('input', update);
  update();
}

if (!navigator.gpu) {
  status.textContent = 'WebGPU is not available in this browser. Use a current browser with WebGPU enabled to view the preview.';
  status.style.borderLeftColor = '#e58c4b';
} else {
  start().catch(error => {
    console.error(error);
    status.textContent = `WebGPU could not be initialised: ${error.message}`;
    status.style.borderLeftColor = '#e58c4b';
  });
}

async function start() {
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error('No compatible WebGPU adapter was found.');
  const device = await adapter.requestDevice();
  const context = canvas.getContext('webgpu');
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: 'opaque' });

  const shader = await fetch('./shader.wgsl').then(response => {
    if (!response.ok) throw new Error(`shader.wgsl returned HTTP ${response.status}`);
    return response.text();
  });
  const module = device.createShaderModule({ code: shader });
  const pipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module, entryPoint: 'vertexMain' },
    fragment: { module, entryPoint: 'fragmentMain', targets: [{ format }] },
    primitive: { topology: 'triangle-list' }
  });

  // Must match shader CameraMedium: 20 f32 values = 80 bytes.
  // resolution.xy, time, pad; orbit.xy, distance, pad; beta_d, beta_b, b_inf.
  const uniformData = new Float32Array(20);
  const uniformBuffer = device.createBuffer({ size: uniformData.byteLength, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: uniformBuffer } }] });
  const startTime = performance.now();
  let yaw = 0.35;
  let pitch = 0.15;
  let dragging = false;
  let lastX = 0;
  let lastY = 0;
  canvas.addEventListener('pointerdown', event => { dragging = true; lastX = event.clientX; lastY = event.clientY; canvas.setPointerCapture(event.pointerId); });
  canvas.addEventListener('pointerup', () => { dragging = false; });
  canvas.addEventListener('pointermove', event => {
    if (!dragging) return;
    yaw += (event.clientX - lastX) * 0.01;
    pitch = Math.max(-1.2, Math.min(1.2, pitch + (event.clientY - lastY) * 0.01));
    lastX = event.clientX; lastY = event.clientY;
  });

  status.textContent = 'WebGPU preview active. Drag to orbit; adjust medium coefficients below.';
  const frame = now => {
    const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.floor(canvas.clientWidth * pixelRatio));
    const height = Math.max(1, Math.floor(canvas.clientHeight * pixelRatio));
    if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
    uniformData[0] = width; uniformData[1] = height; uniformData[2] = (now - startTime) * 0.001;
    uniformData[4] = yaw; uniformData[5] = pitch; uniformData[6] = 4.0;
    for (let i = 0; i < 3; i++) uniformData[8 + i] = valueOf(['bdR', 'bdG', 'bdB'][i]);
    for (let i = 0; i < 3; i++) uniformData[12 + i] = valueOf(['bbR', 'bbG', 'bbB'][i]);
    for (let i = 0; i < 3; i++) uniformData[16 + i] = valueOf(['biR', 'biG', 'biB'][i]);
    device.queue.writeBuffer(uniformBuffer, 0, uniformData);
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 1 }, loadOp: 'clear', storeOp: 'store' }] });
    pass.setPipeline(pipeline); pass.setBindGroup(0, bindGroup); pass.draw(3); pass.end();
    device.queue.submit([encoder.finish()]);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}
