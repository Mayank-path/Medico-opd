// Concrete Deepgram Nova-2 Medical STT Provider (Mumbai AWS ap-south-1 / Zero Data Retention)
// Implements STTProvider interface

import { STTProvider, STTResponse } from './types.ts';

export class DeepgramSTTProvider implements STTProvider {
  private readonly apiKey: string;
  private readonly endpoint: string;

  constructor(apiKey?: string, endpoint?: string) {
    this.apiKey = apiKey ?? Deno.env.get('DEEPGRAM_API_KEY') ?? '';
    // Defaults to Indian region / ap-south-1 endpoint under ZDR
    this.endpoint = endpoint ?? Deno.env.get('DEEPGRAM_ENDPOINT') ?? 'https://api.deepgram.com/v1/listen?model=nova-2-medical&smart_format=true&language=en-IN';
  }

  async transcribe(audioStorageRef: string): Promise<STTResponse> {
    if (!this.apiKey) {
      throw new Error('Deepgram API key not configured in Edge Function environment secrets.');
    }

    if (!audioStorageRef || audioStorageRef.trim() === '') {
      throw new Error('Invalid audio storage reference provided for transcription.');
    }

    const response = await fetch(this.endpoint, {
      method: 'POST',
      headers: {
        'Authorization': `Token ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        url: audioStorageRef,
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Deepgram STT failed with status ${response.status}: ${errText}`);
    }

    const data = await response.json();
    const transcript = data.results?.channels?.[0]?.alternatives?.[0]?.transcript ?? '';
    const confidence = data.results?.channels?.[0]?.alternatives?.[0]?.confidence ?? 0.0;

    return {
      text: transcript,
      confidence: typeof confidence === 'number' ? confidence : 0.0,
      provider: 'deepgram_nova_2_medical_mumbai',
    };
  }
}
