#!/usr/bin/env node

import { Command } from "commander";
import { getAuthenticatedClient, runAuthFlow } from "./auth/oauth.js";
import { generateSlides, generateSlidesFromConfig } from "./slides/generator.js";
import { loadConfig, loadTemplate } from "./slides/config-loader.js";
import { ReviewData } from "./slides/types.js";
import * as fs from "fs/promises";

const program = new Command();

program
  .name("claude-slides")
  .description("Generate Google Slides from config files or review data")
  .version("1.0.0");

program
  .option("--auth", "Run interactive OAuth authentication flow")
  .option("-c, --config <file>", "Slide config JSON file (static content)")
  .option("-t, --template <file>", "Slide template JSON file (with {{variables}})")
  .option("-d, --data <file>", "Data JSON file for template interpolation")
  .option("-i, --input <file>", "Input JSON file for legacy review format (default: stdin)")
  .option("-o, --output <format>", "Output format: url, json", "url")
  .option("--presentation-id <id>", "Update existing presentation instead of creating new")
  .action(async (options) => {
    try {
      if (options.auth) {
        await runAuthFlow();
        process.exit(0);
      }

      const auth = await getAuthenticatedClient();

      // Mode 1: Config file (static content)
      if (options.config) {
        const config = await loadConfig(options.config);
        if (options.presentationId) {
          config.presentationId = options.presentationId;
        }
        const result = await generateSlidesFromConfig(auth, config);
        outputResult(result, options.output);
        return;
      }

      // Mode 2: Template + Data (dynamic content)
      if (options.template) {
        if (!options.data) {
          throw new Error("--template requires --data to provide values");
        }
        const dataContent = await fs.readFile(options.data, "utf-8");
        const data = JSON.parse(dataContent);
        const config = await loadTemplate(options.template, data);
        if (options.presentationId) {
          config.presentationId = options.presentationId;
        }
        const result = await generateSlidesFromConfig(auth, config);
        outputResult(result, options.output);
        return;
      }

      // Mode 3: Legacy review data (stdin or --input)
      let inputJson: string;

      if (options.input) {
        inputJson = await fs.readFile(options.input, "utf-8");
      } else {
        inputJson = await readStdin();
      }

      const reviewData: ReviewData = JSON.parse(inputJson);
      const result = await generateSlides(auth, reviewData);
      outputResult(result, options.output);

    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error("Error:", message);
      process.exit(1);
    }
  });

function outputResult(
  result: { presentationId: string; presentationUrl: string },
  format: string
): void {
  if (format === "json") {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(result.presentationUrl);
  }
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];

  return new Promise((resolve, reject) => {
    if (process.stdin.isTTY) {
      reject(
        new Error(
          "No input received. Use --config, --template, or provide JSON via stdin."
        )
      );
      return;
    }

    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () =>
      resolve(Buffer.concat(chunks).toString("utf-8"))
    );
    process.stdin.on("error", reject);
  });
}

program.parse();
