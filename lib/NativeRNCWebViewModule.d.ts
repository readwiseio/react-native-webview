import type { TurboModule } from 'react-native';
import { Double } from 'react-native/Libraries/Types/CodegenTypes';
export interface Spec extends TurboModule {
    isFileUploadSupported(): Promise<boolean>;
    shouldStartLoadWithLockIdentifier(shouldStart: boolean, lockIdentifier: Double): void;
    callAsyncJavaScript(viewTag: Double, functionBody: string, argument: string): Promise<string | null>;
}
declare const _default: Spec;
export default _default;
