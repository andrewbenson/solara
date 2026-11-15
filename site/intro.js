const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

const powerUpPalette = ["#FF6AFF", "#FE8097", "#FF9966", "#FCE0FF", "#FA62B1"];
const washGain = 7;
const haloGain = 3;

function springParams(response, dampingRatio) {
  return { stiffness: (2 * Math.PI / response) ** 2, damping: 4 * Math.PI * dampingRatio / response, mass: 1 };
}

function solveSpring(p, from, to, t) {
  const zeta = p.damping / (2 * Math.sqrt(p.stiffness * p.mass));
  const omega0 = Math.sqrt(p.stiffness / p.mass);
  const x0 = to - from;
  if (zeta < 1) {
    const omega1 = omega0 * Math.sqrt(1 - zeta * zeta);
    const envelope = Math.exp(-zeta * omega0 * t);
    return to - envelope * ((zeta * omega0 * x0) / omega1 * Math.sin(omega1 * t) + x0 * Math.cos(omega1 * t));
  }
  return to - Math.exp(-omega0 * t) * (x0 + omega0 * x0 * t);
}

const sunRise = { hidden: 56, delay: 0.25, spring: springParams(0.56, 0.9) };
const sunDrift = { hidden: 6, delay: 0.25, spring: springParams(0.6, 1) };

function trackAt(track, elapsed) {
  if (elapsed < track.delay) return track.hidden;
  return solveSpring(track.spring, track.hidden, 0, elapsed - track.delay);
}

function hexToRgb(hex) {
  const v = parseInt(hex.slice(1), 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

function toOklab([r, g, b]) {
  const lin = (x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4);
  const [lr, lg, lb] = [lin(r), lin(g), lin(b)];
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

const vertexSource = `
attribute vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
`;

const washSource = `
precision highp float;
uniform vec2 resolution;
uniform vec4 colors[5];
uniform int colorCount;
uniform float time;
uniform float gain;

float easeOutExpo(float t) { return t == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t); }
float easeInOutQuart(float t) { return t < 0.5 ? 8.0 * t * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 4.0) * 0.5; }
float shiftCenter(float v, float o) { float mid = 1.0 - o; return v <= 0.5 ? v * 2.0 * mid : mid + o * 2.0 * (v - 0.5); }

vec3 oklabToLinear(vec3 lab) {
  vec3 lms = vec3(dot(lab, vec3(1.0, 0.396337777, 0.215803757)),
                  dot(lab, vec3(1.0, -0.105561346, -0.0638541728)),
                  dot(lab, vec3(1.0, -0.0894841775, -1.29148555)));
  lms = lms * lms * lms;
  return vec3(dot(lms, vec3(4.0767417, -3.3077116, 0.230969936)),
              dot(lms, vec3(-1.26843798, 2.60975742, -0.341319382)),
              dot(lms, vec3(-0.00419608643, -0.703418612, 1.70761466)));
}

float linearToSrgb(float c) {
  float ac = abs(c);
  if (ac <= 0.0031308) return c * 12.92;
  return sign(c) * (pow(ac, 0.416666657) * 1.055 - 0.055);
}

vec4 paletteAt(int i) {
  vec4 c = colors[0];
  for (int k = 0; k < 5; k++) { if (k == i) c = colors[k]; }
  return c;
}

vec4 samplePalette(int n1, float v) {
  float f = float(n1) * v;
  int i = int(floor(f));
  vec4 a = paletteAt(i);
  vec4 b = paletteAt(i + 1 > n1 ? n1 : i + 1);
  return mix(a, b, smoothstep(0.0, 1.0, f - float(i)));
}

float windowMask(vec2 uv) {
  float k = (uv.y - 0.5) * 0.25;
  float left = smoothstep(0.0, 0.45, uv.x + k);
  float right = 1.0 - smoothstep(0.55, 1.0, uv.x - k);
  float top = smoothstep(0.0, 0.2, uv.y);
  float bottom = 1.0 - smoothstep(0.85, 1.0, uv.y);
  return left * right * top * bottom;
}

vec4 gradient(vec2 uv, float progress) {
  float c = uv.x;
  float p = progress;
  if (c >= 0.2 && c < 0.4) p = progress - 0.025;
  else if (c >= 0.4 && c < 0.6) p = progress - 0.05;
  else if (c >= 0.6 && c < 0.8) p = progress - 0.025;
  p = clamp(p, 0.0, 1.0);
  float head = 1.0 - easeInOutQuart(p) * 0.95;
  float along = uv.y * 0.4;
  float bend = (1.0 - pow(abs(uv.x - 0.5) + 0.5, 5.0)) * -0.05;
  int n1 = colorCount - 1;
  bool past = along > head;
  float v = past ? 1.0 : max(bend + along / head, 0.0);
  vec4 col = samplePalette(n1, v);
  col.a *= p * 0.5 + 0.5;
  if (past) {
    vec4 trail = samplePalette(n1, max(bend + along, 0.0));
    trail.a *= p * 0.5;
    float edge = easeOutExpo(1.0 - p) * 0.05;
    col = mix(col, trail, clamp((along - head) / edge, 0.0, 1.0));
  }
  vec3 lin = oklabToLinear(col.rgb);
  return vec4(linearToSrgb(lin.r), linearToSrgb(lin.g), linearToSrgb(lin.b), col.a * 0.1);
}

void main() {
  vec2 screen = vec2(gl_FragCoord.x / resolution.x, 1.0 - gl_FragCoord.y / resolution.y);
  float o = 0.5;
  vec2 uv = vec2(shiftCenter(screen.x, o), clamp((screen.y - 0.2) * 1.25, 0.0, 1.0));
  float t = time * 0.75 + 0.45;
  vec4 col = gradient(uv, t);
  col.a = clamp(col.a * windowMask(uv) * clamp(time * 10.0, 0.0, 1.0) * gain, 0.0, 1.0);
  if (t > 1.0) col.a *= 1.0 - clamp((t - 1.0) / 2.0, 0.0, 1.0);
  gl_FragColor = vec4(clamp(col.rgb, 0.0, 1.0) * col.a, col.a);
}
`;

const haloSource = `
precision highp float;
uniform vec2 resolution;
uniform vec3 colorA;
uniform vec3 colorB;
uniform float time;
uniform float inset;
uniform float cornerRadius;
uniform float gain;

vec3 hash33(vec3 p) {
  vec3 p3 = fract(p * vec3(0.1031, 0.11369, 0.13787));
  p3 += dot(p3, p3.yxz + 19.19);
  return -1.0 + 2.0 * fract((p3.xxy + p3.yzz) * p3.zyx);
}

float noise(vec3 p) {
  const float F3 = 0.333333343;
  const float G3 = 0.166666672;
  vec3 s = floor(p + (p.x + p.y + p.z) * F3);
  vec3 x = p - s + (s.x + s.y + s.z) * G3;
  vec3 e = step(vec3(0.0), x - x.yzx);
  vec3 i1 = e * (1.0 - e.zxy);
  vec3 i2 = 1.0 - e.zxy * (1.0 - e);
  vec3 x1 = x - i1 + G3;
  vec3 x2 = x - i2 + 2.0 * G3;
  vec3 x3 = x - 0.5;
  vec4 w = max(0.6 - vec4(dot(x, x), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
  w = w * w * w * w;
  vec4 d = vec4(dot(x, hash33(s)), dot(x1, hash33(s + i1)), dot(x2, hash33(s + i2)), dot(x3, hash33(s + 1.0)));
  return dot(vec4(31.316), d * w);
}

void main() {
  vec2 uv = vec2(gl_FragCoord.x / resolution.x, 1.0 - gl_FragCoord.y / resolution.y);
  float aspect = resolution.x / resolution.y;
  vec2 p = (uv - 0.5) * 2.0;
  p.x *= aspect;
  float inset2 = inset * 2.0;
  float hx = 1.0 - inset2 / resolution.x;
  float hy = 1.0 - inset2 / resolution.y;
  vec2 halfSize = aspect > 1.0 ? vec2(hx * aspect, hy) : vec2(hx, hy / aspect);
  float r = cornerRadius / min(resolution.x - inset2, resolution.y - inset2);
  float dist = abs(length(max(abs(p) - halfSize + r, 0.0)) - r);

  float t = 0.8 * time - 0.18;
  float sweep = (1.0 - pow(2.0, -10.0 * t)) * 1.25;
  vec2 n = p / halfSize;
  float angle = atan(n.y, n.x);
  if (angle < 0.0) angle += 6.28318548;
  float around = mod(1.25 - mod(angle, 6.28318548) * 0.159154937, 1.0);
  if (around > 0.5) around = 1.0 - around;
  around *= 2.0;
  float arc = smoothstep(0.0, 1.0, clamp((abs(around - sweep) - 0.22) * -4.5454545, 0.0, 1.0));

  float line = smoothstep(0.0, 1.0, clamp((dist - 0.025) * -40.0, 0.0, 1.0)) * arc * 0.4;

  float nz = noise(vec3(p * 0.5, time)) + 0.5;
  float glowWidth = mix(0.1, 0.2, nz);
  float shrink = (1.0 - t) * 0.95;
  float g1 = shrink <= 0.0 ? 0.0 : clamp((dist - shrink) / -shrink, 0.0, 1.0);
  float g2 = clamp((dist - glowWidth) / -glowWidth, 0.0, 1.0);
  float g = g1 * g2;
  float glow = g * g * 0.1 * arc * (3.0 - 2.0 * g1) * (3.0 - 2.0 * g2);

  float alpha = clamp((glow + line) * gain, 0.0, 1.0);
  if (t > 1.0) alpha *= 1.0 - clamp((t - 1.0) / 0.2, 0.0, 1.0);
  vec3 rgb = clamp(mix(colorA, colorB, nz) + line, 0.0, 1.0);
  gl_FragColor = vec4(rgb * alpha, alpha);
}
`;

function makeSurface(canvas, fragmentSource) {
  const gl = canvas.getContext("webgl", { premultipliedAlpha: true, alpha: true, antialias: false });
  if (!gl) return null;
  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
    return shader;
  };
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.useProgram(program);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const position = gl.getAttribLocation(program, "position");
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  const uniform = (name) => gl.getUniformLocation(program, name);
  return {
    gl,
    uniform,
    size() {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      const width = canvas.clientWidth;
      const height = canvas.clientHeight;
      canvas.width = Math.max(1, Math.round(width * ratio));
      canvas.height = Math.max(1, Math.round(height * ratio));
      gl.viewport(0, 0, canvas.width, canvas.height);
      return { width, height, ratio };
    },
    draw() {
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    },
    clear() {
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
    },
  };
}

function setUpIntro() {
  const sun = document.getElementById("sun");
  const mark = document.getElementById("mark");
  const washCanvas = document.getElementById("wash");
  const haloCanvas = document.getElementById("halo");
  if (!sun || !mark || !washCanvas || !haloCanvas) return;

  const placeSun = (x, y) => {
    const scale = mark.clientWidth / 100 || 1;
    sun.style.transform = `translate(${x * scale}px, ${y * scale}px)`;
  };

  let wash = null;
  let halo = null;
  try {
    wash = makeSurface(washCanvas, washSource);
    halo = makeSurface(haloCanvas, haloSource);
  } catch {
    wash = null;
    halo = null;
  }

  if (wash) {
    const labs = powerUpPalette.map((hex) => toOklab(hexToRgb(hex)));
    const flat = new Float32Array(20);
    labs.forEach((lab, i) => flat.set([...lab, 1], i * 4));
    wash.gl.uniform4fv(wash.uniform("colors"), flat);
    wash.gl.uniform1i(wash.uniform("colorCount"), labs.length);
    wash.gl.uniform1f(wash.uniform("gain"), washGain);
  }
  if (halo) {
    halo.gl.uniform3fv(halo.uniform("colorA"), hexToRgb(powerUpPalette[0]));
    halo.gl.uniform3fv(halo.uniform("colorB"), hexToRgb(powerUpPalette[1]));
    halo.gl.uniform1f(halo.uniform("gain"), haloGain);
  }

  const washDuration = 3.75;
  const haloDuration = 2;
  let frame = 0;

  const play = () => {
    cancelAnimationFrame(frame);
    if (reduceMotion.matches) {
      placeSun(0, 0);
      wash?.clear();
      halo?.clear();
      return;
    }
    if (wash) {
      wash.size();
      wash.gl.uniform2f(wash.uniform("resolution"), washCanvas.width, washCanvas.height);
    }
    if (halo) {
      const { width, height, ratio } = halo.size();
      halo.gl.uniform2f(halo.uniform("resolution"), width * ratio, height * ratio);
      halo.gl.uniform1f(halo.uniform("inset"), 50 * ratio);
      halo.gl.uniform1f(halo.uniform("cornerRadius"), 22 * ratio);
    }
    let start = null;
    const tick = (now) => {
      if (start === null) start = now;
      const elapsed = (now - start) / 1000;
      placeSun(trackAt(sunDrift, elapsed), trackAt(sunRise, elapsed));
      if (wash) {
        if (elapsed < washDuration) {
          wash.gl.uniform1f(wash.uniform("time"), elapsed);
          wash.draw();
        } else {
          wash.clear();
        }
      }
      if (halo) {
        if (elapsed < haloDuration) {
          halo.gl.uniform1f(halo.uniform("time"), elapsed);
          halo.draw();
        } else {
          halo.clear();
        }
      }
      if (elapsed < washDuration) frame = requestAnimationFrame(tick);
      else placeSun(0, 0);
    };
    placeSun(sunDrift.hidden, sunRise.hidden);
    frame = requestAnimationFrame(tick);
  };

  mark.addEventListener("click", play);
  play();
}

setUpIntro();
