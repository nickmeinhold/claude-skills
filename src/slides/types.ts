export interface ReviewData {
  prNumber: number;
  prTitle: string;
  prAuthor: string;
  prDate: string;
  repository: string;

  summary: string;
  changes: string[];

  qualityAssessment: {
    codeQuality: { status: "pass" | "warning" | "issue"; notes: string };
    tests: { status: "pass" | "warning" | "issue"; notes: string };
    security: { status: "pass" | "warning" | "issue"; notes: string };
    performance: { status: "pass" | "warning" | "issue"; notes: string };
  };

  issuesFound: string[];
  suggestions: string[];

  verdict: "APPROVE" | "REQUEST_CHANGES" | "COMMENT";
  verdictExplanation: string;

  businessImpact?: string;
  riskLevel?: "low" | "medium" | "high";
  riskFactors?: string[];
  affectedAreas?: string[];
}

export interface SlideGenerationResult {
  presentationId: string;
  presentationUrl: string;
}

// Config-based slide types
export interface RgbColor {
  red: number;
  green: number;
  blue: number;
}

export interface SlideElement {
  text: string;
  x: number;
  y: number;
  w: number;
  h: number;
  size: number;
  color: string | RgbColor;
  bold?: boolean;
}

export interface SlideDefinition {
  background?: string | RgbColor;
  elements: SlideElement[];
  notes?: string;
}

export interface SlideTheme {
  colors: Record<string, RgbColor>;
  defaultFont?: string;
}

export interface SlideConfig {
  title: string;
  theme?: SlideTheme;
  slides: SlideDefinition[];
  presentationId?: string; // For updating existing presentations
}
