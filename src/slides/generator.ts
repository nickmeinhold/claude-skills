import { google, slides_v1 } from "googleapis";
import { OAuth2Client } from "google-auth-library";
import {
  ReviewData,
  SlideGenerationResult,
  SlideConfig,
  SlideElement,
  RgbColor,
} from "./types.js";
import { resolveColor } from "./config-loader.js";
import { getStatusEmoji } from "./templates.js";

// Points to EMU (English Metric Units) conversion
const PT_TO_EMU = 12700;
function pt(points: number): number {
  return points * PT_TO_EMU;
}

/**
 * Generate slides from a SlideConfig
 */
export async function generateSlidesFromConfig(
  auth: OAuth2Client,
  config: SlideConfig
): Promise<SlideGenerationResult> {
  const slidesApi = google.slides({ version: "v1", auth });
  const themeColors = config.theme?.colors;

  let presentationId = config.presentationId;

  if (presentationId) {
    // Update existing presentation
    const existing = await slidesApi.presentations.get({ presentationId });
    const existingSlides = existing.data.slides || [];

    if (existingSlides.length > 0) {
      const deleteRequests = existingSlides.map((slide) => ({
        deleteObject: { objectId: slide.objectId },
      }));
      await slidesApi.presentations.batchUpdate({
        presentationId,
        requestBody: { requests: deleteRequests },
      });
    }
  } else {
    // Create new presentation
    const presentation = await slidesApi.presentations.create({
      requestBody: { title: config.title },
    });
    presentationId = presentation.data.presentationId!;

    // Delete the default blank slide
    const defaultSlideId = presentation.data.slides![0].objectId;
    if (defaultSlideId) {
      await slidesApi.presentations.batchUpdate({
        presentationId,
        requestBody: {
          requests: [{ deleteObject: { objectId: defaultSlideId } }],
        },
      });
    }
  }

  // Build all requests
  const requests: slides_v1.Schema$Request[] = [];

  config.slides.forEach((slide, slideIndex) => {
    const slideId = `slide_${slideIndex}_${Date.now()}`;

    // Create slide with BLANK layout
    requests.push({
      createSlide: {
        objectId: slideId,
        insertionIndex: slideIndex,
        slideLayoutReference: { predefinedLayout: "BLANK" },
      },
    });

    // Set background if specified
    if (slide.background) {
      const bgColor = resolveColor(slide.background, themeColors);
      requests.push({
        updatePageProperties: {
          objectId: slideId,
          pageProperties: {
            pageBackgroundFill: {
              solidFill: { color: { rgbColor: bgColor } },
            },
          },
          fields: "pageBackgroundFill",
        },
      });
    }

    // Add text elements
    slide.elements.forEach((elem, elemIndex) => {
      const elementId = `${slideId}_text_${elemIndex}`;
      requests.push(...createTextBoxRequests(slideId, elementId, elem, themeColors));
    });
  });

  // Apply in batches (API limit is ~100 per request)
  const BATCH_SIZE = 50;
  for (let i = 0; i < requests.length; i += BATCH_SIZE) {
    const batch = requests.slice(i, i + BATCH_SIZE);
    await slidesApi.presentations.batchUpdate({
      presentationId,
      requestBody: { requests: batch },
    });
  }

  // Add speaker notes
  const notesRequests: slides_v1.Schema$Request[] = [];
  const presentation = await slidesApi.presentations.get({ presentationId });

  presentation.data.slides?.forEach((slide, i) => {
    if (i >= config.slides.length || !config.slides[i].notes) return;

    const notesId =
      slide.slideProperties?.notesPage?.notesProperties?.speakerNotesObjectId;
    if (notesId) {
      notesRequests.push({
        insertText: {
          objectId: notesId,
          text: config.slides[i].notes!,
          insertionIndex: 0,
        },
      });
    }
  });

  if (notesRequests.length > 0) {
    await slidesApi.presentations.batchUpdate({
      presentationId,
      requestBody: { requests: notesRequests },
    });
  }

  return {
    presentationId,
    presentationUrl: `https://docs.google.com/presentation/d/${presentationId}/edit`,
  };
}

function createTextBoxRequests(
  slideId: string,
  elementId: string,
  elem: SlideElement,
  themeColors?: Record<string, RgbColor>
): slides_v1.Schema$Request[] {
  const color = resolveColor(elem.color, themeColors);

  return [
    {
      createShape: {
        objectId: elementId,
        shapeType: "TEXT_BOX",
        elementProperties: {
          pageObjectId: slideId,
          size: {
            width: { magnitude: pt(elem.w), unit: "EMU" },
            height: { magnitude: pt(elem.h), unit: "EMU" },
          },
          transform: {
            scaleX: 1,
            scaleY: 1,
            translateX: pt(elem.x),
            translateY: pt(elem.y),
            unit: "EMU",
          },
        },
      },
    },
    {
      insertText: {
        objectId: elementId,
        text: elem.text,
      },
    },
    {
      updateTextStyle: {
        objectId: elementId,
        style: {
          fontFamily: "Arial",
          fontSize: { magnitude: elem.size, unit: "PT" },
          foregroundColor: { opaqueColor: { rgbColor: color } },
          bold: elem.bold || false,
        },
        fields: "fontFamily,fontSize,foregroundColor,bold",
      },
    },
    {
      updateParagraphStyle: {
        objectId: elementId,
        style: {
          lineSpacing: 115,
          alignment: "START",
        },
        fields: "lineSpacing,alignment",
      },
    },
  ];
}

/**
 * Legacy function: Generate slides from ReviewData
 * Kept for backward compatibility
 */
export async function generateSlides(
  auth: OAuth2Client,
  reviewData: ReviewData
): Promise<SlideGenerationResult> {
  const slides = google.slides({ version: "v1", auth });

  const presentation = await slides.presentations.create({
    requestBody: {
      title: `PR Review: ${reviewData.prTitle}`,
    },
  });

  const presentationId = presentation.data.presentationId!;
  const defaultSlideId = presentation.data.slides![0].objectId!;

  const slideIds = {
    title: `title_${Date.now()}`,
    summary: `summary_${Date.now()}`,
    impact: `impact_${Date.now()}`,
    risks: `risks_${Date.now()}`,
    verdict: `verdict_${Date.now()}`,
  };

  const createRequests: slides_v1.Schema$Request[] = [
    { deleteObject: { objectId: defaultSlideId } },
    ...Object.values(slideIds).map((id) => ({
      createSlide: {
        objectId: id,
        slideLayoutReference: { predefinedLayout: "TITLE_AND_BODY" as const },
      },
    })),
  ];

  await slides.presentations.batchUpdate({
    presentationId,
    requestBody: { requests: createRequests },
  });

  const updatedPresentation = await slides.presentations.get({
    presentationId,
  });

  const contentRequests: slides_v1.Schema$Request[] = [];

  for (const slide of updatedPresentation.data.slides || []) {
    const slideId = slide.objectId!;
    const placeholders = slide.pageElements?.filter(
      (el) => el.shape?.placeholder
    );

    const titlePlaceholder = placeholders?.find(
      (el) => el.shape?.placeholder?.type === "TITLE"
    );
    const bodyPlaceholder = placeholders?.find(
      (el) => el.shape?.placeholder?.type === "BODY"
    );

    const titleId = titlePlaceholder?.objectId ?? undefined;
    const bodyId = bodyPlaceholder?.objectId ?? undefined;

    if (slideId === slideIds.title) {
      contentRequests.push(...buildTitleContent(titleId, bodyId, reviewData));
    } else if (slideId === slideIds.summary) {
      contentRequests.push(...buildSummaryContent(titleId, bodyId, reviewData));
    } else if (slideId === slideIds.impact) {
      contentRequests.push(...buildImpactContent(titleId, bodyId, reviewData));
    } else if (slideId === slideIds.risks) {
      contentRequests.push(...buildRisksContent(titleId, bodyId, reviewData));
    } else if (slideId === slideIds.verdict) {
      contentRequests.push(...buildVerdictContent(titleId, bodyId, reviewData));
    }
  }

  if (contentRequests.length > 0) {
    await slides.presentations.batchUpdate({
      presentationId,
      requestBody: { requests: contentRequests },
    });
  }

  return {
    presentationId,
    presentationUrl: `https://docs.google.com/presentation/d/${presentationId}/edit`,
  };
}

function buildTitleContent(
  titleId: string | undefined,
  bodyId: string | undefined,
  data: ReviewData
): slides_v1.Schema$Request[] {
  const requests: slides_v1.Schema$Request[] = [];

  if (titleId) {
    requests.push({
      insertText: {
        objectId: titleId,
        text: data.prTitle,
        insertionIndex: 0,
      },
    });
  }

  if (bodyId) {
    const subtitle = `PR #${data.prNumber} | ${data.repository}\n${data.prAuthor} | ${formatDate(data.prDate)}`;
    requests.push({
      insertText: {
        objectId: bodyId,
        text: subtitle,
        insertionIndex: 0,
      },
    });
  }

  return requests;
}

function buildSummaryContent(
  titleId: string | undefined,
  bodyId: string | undefined,
  data: ReviewData
): slides_v1.Schema$Request[] {
  const requests: slides_v1.Schema$Request[] = [];

  if (titleId) {
    requests.push({
      insertText: {
        objectId: titleId,
        text: "What Changed",
        insertionIndex: 0,
      },
    });
  }

  if (bodyId) {
    const lines = [data.summary, "", ...data.changes.map((c) => `- ${c}`)];
    requests.push({
      insertText: {
        objectId: bodyId,
        text: lines.join("\n"),
        insertionIndex: 0,
      },
    });
  }

  return requests;
}

function buildImpactContent(
  titleId: string | undefined,
  bodyId: string | undefined,
  data: ReviewData
): slides_v1.Schema$Request[] {
  const requests: slides_v1.Schema$Request[] = [];

  if (titleId) {
    requests.push({
      insertText: {
        objectId: titleId,
        text: "Impact Assessment",
        insertionIndex: 0,
      },
    });
  }

  if (bodyId) {
    const lines: string[] = [];

    if (data.businessImpact) {
      lines.push("Business Impact:", data.businessImpact, "");
    }

    if (data.affectedAreas && data.affectedAreas.length > 0) {
      lines.push("Affected Areas:");
      lines.push(...data.affectedAreas.map((a) => `- ${a}`));
      lines.push("");
    }

    lines.push("Quality Summary:");
    const qa = data.qualityAssessment;
    lines.push(`- Code Quality: ${getStatusEmoji(qa.codeQuality.status)}`);
    lines.push(`- Tests: ${getStatusEmoji(qa.tests.status)}`);
    lines.push(`- Security: ${getStatusEmoji(qa.security.status)}`);
    lines.push(`- Performance: ${getStatusEmoji(qa.performance.status)}`);

    requests.push({
      insertText: {
        objectId: bodyId,
        text: lines.join("\n"),
        insertionIndex: 0,
      },
    });
  }

  return requests;
}

function buildRisksContent(
  titleId: string | undefined,
  bodyId: string | undefined,
  data: ReviewData
): slides_v1.Schema$Request[] {
  const requests: slides_v1.Schema$Request[] = [];

  if (titleId) {
    requests.push({
      insertText: {
        objectId: titleId,
        text: "Risk Assessment",
        insertionIndex: 0,
      },
    });
  }

  if (bodyId) {
    const lines: string[] = [];

    const riskLevel = data.riskLevel || "low";
    lines.push(`Risk Level: ${riskLevel.toUpperCase()}`, "");

    if (data.riskFactors && data.riskFactors.length > 0) {
      lines.push("Risk Factors:");
      lines.push(...data.riskFactors.map((r) => `- ${r}`));
      lines.push("");
    }

    if (data.issuesFound && data.issuesFound.length > 0) {
      lines.push("Issues Found:");
      lines.push(...data.issuesFound.map((i) => `- ${i}`));
    } else {
      lines.push("No blocking issues found.");
    }

    requests.push({
      insertText: {
        objectId: bodyId,
        text: lines.join("\n"),
        insertionIndex: 0,
      },
    });
  }

  return requests;
}

function buildVerdictContent(
  titleId: string | undefined,
  bodyId: string | undefined,
  data: ReviewData
): slides_v1.Schema$Request[] {
  const requests: slides_v1.Schema$Request[] = [];

  if (titleId) {
    requests.push({
      insertText: {
        objectId: titleId,
        text: `Recommendation: ${data.verdict}`,
        insertionIndex: 0,
      },
    });
  }

  if (bodyId) {
    const lines: string[] = [data.verdictExplanation, ""];

    if (data.suggestions && data.suggestions.length > 0) {
      lines.push("Suggestions:");
      lines.push(...data.suggestions.map((s) => `- ${s}`));
    }

    requests.push({
      insertText: {
        objectId: bodyId,
        text: lines.join("\n"),
        insertionIndex: 0,
      },
    });
  }

  return requests;
}

function formatDate(isoDate: string): string {
  return new Date(isoDate).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}
