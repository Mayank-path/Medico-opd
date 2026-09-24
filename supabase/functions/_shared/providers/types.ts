// Supabase Edge Functions: Provider Abstraction Interfaces
// Invariant 14 & Phase 3 Provider Independence

export interface STTResponse {
  text: string;
  confidence: number;
  provider: string;
}

export interface PrescribedMedication {
  drug_name: string;
  dosage: string;
  frequency: string;
  duration: string;
  instructions: string;
}

export interface StructuredDraft {
  chief_complaints: string[];
  history_of_present_illness: string;
  examination_findings: string[];
  provisional_diagnosis: string[];
  medications: PrescribedMedication[];
  investigations_ordered: string[];
  follow_up_advice: string;
  model_metadata?: {
    model_name: string;
    prompt_version: string;
    processing_timestamp: string;
  };
}

export interface STTProvider {
  transcribe(audioStorageRef: string): Promise<STTResponse>;
}

export interface LLMProvider {
  generateDraft(privacyProcessedText: string): Promise<StructuredDraft>;
}
