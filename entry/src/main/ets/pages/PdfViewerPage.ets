import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit';
import { PdfFileParams } from '../model/RouteParams';
import { PdfFileCache } from '../service/PdfFileCache';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';

/** PDF 只读查看页：SMB 分块下载到沙箱 → 原生 PDF Kit 渲染（连续滚动/缩放/页码） */
@Component
export default struct PdfViewerPage {
  params: PdfFileParams = { path: '', name: '', size: 0 };

  private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private localPath: string = '';
  private disposed: boolean = false;
  private firstShown: boolean = true;
  private listenersRegistered: boolean = false;

  @State loading: boolean = true;
  @State progress: number = 0;
  @State errorText: string = '';
  @State currentPage: number = 0;
  @State totalPages: number = 0;

  aboutToAppear(): void {
    this.progress = 0;
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.release();
  }

  private release(): void {
    try {
      this.controller.releaseDocument();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pdf releaseDocument failed: %{public}s', JSON.stringify(e));
    }
    if (this.localPath.length > 0) {
      PdfFileCache.cleanup(this.localPath);
      this.localPath = '';
    }
  }

  private async open(): Promise<void> {
    const p = this.params;
    if (p === undefined || p === null || p.path.length === 0) {
      this.loading = false;
      this.errorText = '文件参数无效';
      return;
    }
    this.loading = true;
    this.errorText = '';
    this.progress = 0;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const localPath = await PdfFileCache.prepare(ctx, p.path, p.size,
        (written: number, total: number) => {
          const pct = total > 0 ? Math.floor(written * 60 / total) : 0;
          this.progress = Math.min(pct, 60);
        });
      this.localPath = localPath;
      if (this.disposed) {
        this.release();
        return;
      }
      const result = await this.controller.loadDocument(localPath, undefined, 0, (prog: number) => {
        this.progress = 60 + Math.round(Math.max(0, Math.min(1, prog)) * 40);
      });
      if (this.disposed) {
        this.release();
        return;
      }
      if (result !== pdfService.ParseResult.PARSE_SUCCESS) {
        this.errorText = result === pdfService.ParseResult.PARSE_ERROR_PASSWORD
          ? '该 PDF 已加密，暂不支持查看'
          : '无法打开该 PDF 文件';
        this.loading = false;
        return;
      }
      this.registerListeners();
      this.loading = false;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorText = e instanceof Error ? e.message : 'PDF 打开失败';
      this.loading = false;
      hilog.warn(DOMAIN, TAG, 'pdf open failed path=%{public}s err=%{public}s', p.path, this.errorText);
    }
  }

  /** 监听页码变化：覆盖层右下角显示 当前页/总页 */
  private registerListeners(): void {
    if (!this.listenersRegistered) {
      this.listenersRegistered = true;
      this.controller.registerPageChangedListener((index: number) => {
        if (this.disposed) {
          return;
        }
        this.currentPage = index;
      });
      this.controller.registerPageCountChangedListener((count: number) => {
        if (this.disposed) {
          return;
        }
        this.totalPages = count;
      });
    }
    this.currentPage = this.controller.getPageIndex();
    this.totalPages = this.controller.getPageCount();
  }

  @Builder
  progressView() {
    Column({ space: 12 }) {
      Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
        .width(220)
        .color($r('app.color.theme_primary'))
      Text('正在打开 PDF ' + this.progress + '%')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.theme_bg'))
  }

  @Builder
  errorView() {
    Column({ space: 10 }) {
      Text(this.errorText)
        .fontSize(14)
        .fontColor($r('app.color.text_main'))
        .textAlign(TextAlign.Center)
        .padding({ left: 30, right: 30 })
      Button('重试')
        .fontSize(14)
        .height(36)
        .backgroundColor($r('app.color.theme_primary'))
        .onClick(() => {
          this.open();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.theme_bg'))
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        PdfView({
          controller: this.controller,
          pageLayout: pdfService.PageLayout.LAYOUT_SINGLE,
          isContinuous: true,
          showScroll: true,
          pageFit: pdfService.PageFit.FIT_WIDTH
        })
          .width('100%')
          .height('100%')

        if (!this.loading && this.errorText.length === 0 && this.totalPages > 0) {
          Text((this.currentPage + 1) + ' / ' + this.totalPages)
            .fontSize(12)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('#99000000')
            .borderRadius(12)
            .margin({ right: 14, bottom: 18 })
        }

        if (this.loading) {
          this.progressView()
        } else if (this.errorText.length > 0) {
          this.errorView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
    }
    .title(this.params.name.length > 0 ? this.params.name : 'PDF')
    .hideTitleBar(false)
    .onShown(() => {
      if (this.firstShown) {
        this.firstShown = false;
        this.open();
      }
    })
  }
}
