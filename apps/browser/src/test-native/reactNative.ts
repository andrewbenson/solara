export const View = () => null;

export const StyleSheet = { hairlineWidth: 0.5 };

export const processColor = (color: unknown) => color;

export const NativeModules: Record<string, unknown> = {};

export const Animated = { createAnimatedComponent: <Component>(component: Component) => component };

export const findNodeHandle = () => null;

export const Easing = { out: (curve: (value: number) => number) => (value: number) => 1 - curve(1 - value), quad: (value: number) => value * value };
