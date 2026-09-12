import { VideoEntry } from './VideoEntry';

export interface BrowserParams {
  sharePath: string;
}

export interface PlayerParams {
  files: VideoEntry[];
  index: number;
}

export interface ImageViewerParams {
  files: VideoEntry[];
  index: number;
}

export interface SharesParams {
  host: string;
}
