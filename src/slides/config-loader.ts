import * as fs from "fs/promises";
import {
  SlideConfig,
  SlideDefinition,
  SlideElement,
  RgbColor,
} from "./types.js";

const DEFAULT_COLORS: Record<string, RgbColor> = {
  white: { red: 1, green: 1, blue: 1 },
  black: { red: 0, green: 0, blue: 0 },
  darkBlue: { red: 0.102, green: 0.212, blue: 0.365 },
  accentBlue: { red: 0.193, green: 0.51, blue: 0.784 },
  darkGray: { red: 0.176, green: 0.216, blue: 0.282 },
  success: { red: 0.2, green: 0.7, blue: 0.3 },
  warning: { red: 0.9, green: 0.6, blue: 0.1 },
  danger: { red: 0.8, green: 0.2, blue: 0.2 },
};

export async function loadConfig(configPath: string): Promise<SlideConfig> {
  const content = await fs.readFile(configPath, "utf-8");
  const config = JSON.parse(content) as SlideConfig;
  return config;
}

export async function loadTemplate(
  templatePath: string,
  data: Record<string, unknown>
): Promise<SlideConfig> {
  const content = await fs.readFile(templatePath, "utf-8");
  const interpolated = interpolateVariables(content, data);
  const config = JSON.parse(interpolated) as SlideConfig;
  return config;
}

function interpolateVariables(
  template: string,
  data: Record<string, unknown>
): string {
  return template.replace(/\{\{(\w+(?:\.\w+)*)\}\}/g, (match, path) => {
    const value = getNestedValue(data, path);
    if (value === undefined) {
      return match; // Keep original if not found
    }
    if (typeof value === "string") {
      // Escape for JSON
      return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
    }
    if (Array.isArray(value)) {
      return value.join("\\n");
    }
    return String(value);
  });
}

function getNestedValue(obj: Record<string, unknown>, path: string): unknown {
  const parts = path.split(".");
  let current: unknown = obj;
  for (const part of parts) {
    if (current === null || current === undefined) return undefined;
    current = (current as Record<string, unknown>)[part];
  }
  return current;
}

export function resolveColor(
  color: string | RgbColor,
  theme?: Record<string, RgbColor>
): RgbColor {
  if (typeof color === "object") {
    return color;
  }
  // Check theme colors first
  if (theme && theme[color]) {
    return theme[color];
  }
  // Check default colors
  if (DEFAULT_COLORS[color]) {
    return DEFAULT_COLORS[color];
  }
  // Parse hex color
  if (color.startsWith("#")) {
    return hexToRgb(color);
  }
  // Default to black
  return DEFAULT_COLORS.black;
}

function hexToRgb(hex: string): RgbColor {
  const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  if (!result) {
    return DEFAULT_COLORS.black;
  }
  return {
    red: parseInt(result[1], 16) / 255,
    green: parseInt(result[2], 16) / 255,
    blue: parseInt(result[3], 16) / 255,
  };
}
