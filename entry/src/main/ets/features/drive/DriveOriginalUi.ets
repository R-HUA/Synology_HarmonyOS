import { DriveOriginalModel } from './DriveOriginalModel';
import { ImagePreview, PreviewInformation } from '../workbench/ImagePreview';

@ComponentV2
export struct DriveOriginalPage {
  @Param model: DriveOriginalModel = new DriveOriginalModel();
  @Param information: PreviewInformation[] = [];
  @Param canDelete: boolean = false;
  @Param canShare: boolean = false;
  @Event onDownload: () => void = (): void => {};
  @Event onDelete: () => void = (): void => {};
  @Event onShare: () => void = (): void => {};

  build() {
    ImagePreview({ source: this.model.pixels ?? '', name: this.model.entry?.name ?? '', busy: this.model.busy,
      original: this.model.originalLoaded, errorText: this.model.errorText, information: this.information,
      video: /\.(?:mp4|mov|mkv|avi|m4v)$/i.test(this.model.entry?.name ?? ''),
      canDownload: this.model.entry !== undefined && this.model.entry.capabilities.canDownload,
      canDelete: this.canDelete, canShare: this.canShare, onDownload: this.onDownload, onDelete: this.onDelete, onShare: this.onShare,
      onViewport: (width: number, height: number): void => { this.model.setViewport(width, height); },
      onRefine: (scale: number): void => { this.model.refine(scale); } })
  }
}
