// Standalone Privacy / Data-Minimization Stage (DPDP Act 2023 Section 8)
// Sits strictly between Transcript and LLM Provider
// Detects and redacts direct personal identifiers while strictly preserving clinical entities

export interface MinimizationResult {
  minimizedText: string;
  categoriesDetected: string[];
  redactionCount: number;
}

export class DataMinimizer {
  // Regex patterns for obvious Indian identifiers
  private static readonly PHONE_REGEX = /(\+91[\-\s]?)?[6-9]\d{9}\b/g;
  private static readonly AADHAAR_REGEX = /\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b/g;
  private static readonly EMAIL_REGEX = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g;
  private static readonly ADDRESS_PINCODE_REGEX = /\b\d{6}\b/g;

  // Pattern for direct patient honorific introductions (e.g. "Mr. Ramesh", "Mrs. Sunita")
  private static readonly NAME_INTRO_REGEX = /\b(Mr\.|Mrs\.|Ms\.|Master|Shri|Smt\.)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b/g;

  /**
   * Processes raw transcript into privacy-minimized clinical dialogue.
   * Strips direct identifiers while preserving:
   * - Medication names, dosages, and frequencies
   * - Symptoms, complaints, and examination observations
   * - Provisional and differential diagnoses
   * - Clinical history, allergies, and lab orders
   */
  public static process(rawTranscript: string): MinimizationResult {
    if (!rawTranscript || rawTranscript.trim() === '') {
      return {
        minimizedText: '',
        categoriesDetected: [],
        redactionCount: 0,
      };
    }

    let resultText = rawTranscript;
    const detectedCategories = new Set<string>();
    let totalRedactions = 0;

    // 1. Phone number redaction
    if (this.PHONE_REGEX.test(resultText)) {
      detectedCategories.add('PHONE_NUMBER_REDACTED');
      resultText = resultText.replace(this.PHONE_REGEX, (match) => {
        totalRedactions++;
        return '[PHONE_REDACTED]';
      });
    }

    // 2. Aadhaar number redaction
    if (this.AADHAAR_REGEX.test(resultText)) {
      detectedCategories.add('AADHAAR_NUMBER_REDACTED');
      resultText = resultText.replace(this.AADHAAR_REGEX, (match) => {
        totalRedactions++;
        return '[AADHAAR_REDACTED]';
      });
    }

    // 3. Email address redaction
    if (this.EMAIL_REGEX.test(resultText)) {
      detectedCategories.add('EMAIL_REDACTED');
      resultText = resultText.replace(this.EMAIL_REGEX, (match) => {
        totalRedactions++;
        return '[EMAIL_REDACTED]';
      });
    }

    // 4. Standalone 6-digit postal PIN code redaction
    if (this.ADDRESS_PINCODE_REGEX.test(resultText)) {
      detectedCategories.add('PINCODE_REDACTED');
      resultText = resultText.replace(this.ADDRESS_PINCODE_REGEX, (match) => {
        totalRedactions++;
        return '[PINCODE_REDACTED]';
      });
    }

    // 5. Patient personal introduction name masking
    if (this.NAME_INTRO_REGEX.test(resultText)) {
      detectedCategories.add('PATIENT_NAME_MASKED');
      resultText = resultText.replace(this.NAME_INTRO_REGEX, (match, prefix, name) => {
        totalRedactions++;
        return `${prefix} [PATIENT_NAME]`;
      });
    }

    return {
      minimizedText: resultText,
      categoriesDetected: Array.from(detectedCategories),
      redactionCount: totalRedactions,
    };
  }
}
