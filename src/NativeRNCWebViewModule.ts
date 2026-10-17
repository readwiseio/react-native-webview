import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type {
  Double,
  EventEmitter,
} from 'react-native/Libraries/Types/CodegenTypes';

export type FastMessageEvent = {
  viewTag: Double;
  data: string;
};

export interface Spec extends TurboModule {
  isFileUploadSupported(): Promise<boolean>;
  shouldStartLoadWithLockIdentifier(
    shouldStart: boolean,
    lockIdentifier: Double
  ): void;
  callAsyncJavaScript(
    viewTag: Double,
    functionBody: string,
    argument: string
  ): Promise<string | null>;
  readonly onFastMessage: EventEmitter<FastMessageEvent>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RNCWebViewModule');
