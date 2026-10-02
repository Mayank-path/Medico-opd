// Edge Function Structured Logging, Redaction, Metrics & Correlation
// Enforces DPDP Act 2023 privacy boundaries and operational visibility.

export interface LogContext {
  requestId: string;
  correlationId: string;
  clinicId?: string;
  clinicIdHash?: string;
  recordingId?: string;
  consultationId?: string;
  attemptCount?: number;
}

export class EdgeRedactor {
  private static readonly JWT_REGEX = /eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}/g;
  private static readonly API_KEY_REGEX = /(?:sk-ant-[a-zA-Z0-9_-]{20,}|Bearer\s+[a-zA-Z0-9._-]{20,}|(?:api[_-]?key|secret|token|service_role)\s*[:=]\s*["']?[a-zA-Z0-9._-]{20,}["']?)/gi;
  private static readonly SIGNED_URL_REGEX = /https?:\/\/[^\s"<>]+(?:\?|&)(?:token|Signature|AWSAccessKeyId|Expires)=[^\s"<>]+/gi;
  private static readonly EMAIL_REGEX = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;
  private static readonly PHONE_REGEX = /(?:\+?91[\-\s]?)?[6-9]\d{9}\b/g;
  private static readonly AADHAAR_REGEX = /\b[2-9]\d{3}[\s\-]?\d{4}[\s\-]?\d{4}\b/g;

  public static redact(text: string | undefined | null): string {
    if (!text) return '';
    return text
      .replace(this.SIGNED_URL_REGEX, '[REDACTED_SIGNED_URL]')
      .replace(this.JWT_REGEX, '[REDACTED_JWT]')
      .replace(this.API_KEY_REGEX, '[REDACTED_API_KEY]')
      .replace(this.EMAIL_REGEX, '[REDACTED_EMAIL]')
      .replace(this.AADHAAR_REGEX, '[REDACTED_AADHAAR]')
      .replace(this.PHONE_REGEX, '[REDACTED_PHONE]');
  }

  public static sanitizeObject(obj: any): any {
    if (obj === null || obj === undefined) return obj;
    if (typeof obj === 'string') return this.redact(obj);
    if (typeof obj === 'number' || typeof obj === 'boolean') return obj;
    if (Array.isArray(obj)) return obj.map((item) => this.sanitizeObject(item));
    if (typeof obj === 'object') {
      const sanitized: Record<string, any> = {};
      for (const [k, v] of Object.entries(obj)) {
        const lowerKey = k.toLowerCase();
        if (
          lowerKey.includes('transcript') ||
          lowerKey.includes('prompt') ||
          lowerKey.includes('audio') ||
          lowerKey.includes('chief_complaint') ||
          lowerKey.includes('diagnosis') ||
          lowerKey.includes('prescription') ||
          lowerKey.includes('notes') ||
          lowerKey.includes('raw_text')
        ) {
          sanitized[k] = '[REDACTED_CLINICAL_PAYLOAD]';
        } else if (
          lowerKey.includes('token') ||
          lowerKey.includes('secret') ||
          lowerKey.includes('password') ||
          lowerKey.includes('key')
        ) {
          sanitized[k] = '[REDACTED_CREDENTIAL]';
        } else {
          sanitized[k] = this.sanitizeObject(v);
        }
      }
      return sanitized;
    }
    return String(obj);
  }

  public static async hashTenantId(clinicId?: string): Promise<string> {
    if (!clinicId) return 'unknown';
    const msgUint8 = new TextEncoder().encode(`medico_clinic_${clinicId}`);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgUint8);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map((b) => b.toString(16).padStart(2, '0')).join('').substring(0, 12);
  }
}

export class EdgeLogger {
  private component: string;
  private context: LogContext;

  constructor(component: string, context: LogContext) {
    this.component = component;
    this.context = context;
  }

  private writeLog(
    severity: 'DEBUG' | 'INFO' | 'WARNING' | 'ERROR',
    event: string,
    operation: string,
    metadata?: Record<string, any>,
    durationMs?: number,
    errorCode?: string
  ) {
    const payload = {
      timestamp: new Date().toISOString(),
      event,
      severity,
      component: this.component,
      operation,
      request_id: this.context.requestId,
      correlation_id: this.context.correlationId,
      clinic_id_hash: this.context.clinicIdHash,
      recording_id: this.context.recordingId,
      consultation_id: this.context.consultationId,
      attempt_count: this.context.attemptCount,
      duration_ms: durationMs,
      error_code: errorCode,
      metadata: metadata ? EdgeRedactor.sanitizeObject(metadata) : undefined,
    };

    console.log(JSON.stringify(payload));
  }

  public info(event: string, operation: string, metadata?: Record<string, any>, durationMs?: number) {
    this.writeLog('INFO', event, operation, metadata, durationMs);
  }

  public warning(
    event: string,
    operation: string,
    errorCode?: string,
    metadata?: Record<string, any>,
    durationMs?: number
  ) {
    this.writeLog('WARNING', event, operation, metadata, durationMs, errorCode);
  }

  public error(
    event: string,
    operation: string,
    errorCode: string,
    metadata?: Record<string, any>,
    durationMs?: number
  ) {
    this.writeLog('ERROR', event, operation, metadata, durationMs, errorCode);
  }

  public metric(name: string, value = 1, labels: Record<string, string> = {}) {
    // Low cardinality validation: strip high cardinality keys
    const cleanLabels: Record<string, string> = {};
    const forbidden = ['patient_id', 'consultation_id', 'recording_id', 'request_id', 'correlation_id', 'clinic_id'];
    for (const [k, v] of Object.entries(labels)) {
      if (!forbidden.includes(k.toLowerCase())) {
        cleanLabels[k] = v;
      }
    }

    const metricPayload = {
      type: 'METRIC',
      metric: name,
      value,
      labels: cleanLabels,
      timestamp: new Date().toISOString(),
    };
    console.log(JSON.stringify(metricPayload));
  }
}
