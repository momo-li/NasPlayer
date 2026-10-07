import { UIContext } from '@kit.ArkUI';

/** 内容已变化的目录集合；BrowserPage 再次可见时消费该标记并静默刷新 */
const dirtyDirs: Set<string> = new Set<string>();

/** 删除二次确认弹窗：取消为默认按钮，删除为红色破坏性按钮，避免误触直接删除 */
export function showDeleteConfirm(ctx: UIContext, name: string, kind: string,
  onConfirm: () => void): void {
  const cancelBtn: AlertDialogButtonOptions = {
    value: '取消',
    action: () => {
    }
  };
  const deleteBtn: AlertDialogButtonOptions = {
    value: '删除',
    fontColor: '#E53935',
    action: onConfirm
  };
  const options: AlertDialogParamWithButtons = {
    title: '确认删除',
    message: '确定要删除' + kind + '“' + name + '”吗？此操作不可恢复。',
    autoCancel: true,
    primaryButton: cancelBtn,
    secondaryButton: deleteBtn
  };
  ctx.showAlertDialog(options);
}

/** 文件所在目录；与 BrowserPage.goBack 的父目录算法保持一致（根目录为 ''） */
export function parentDir(path: string): string {
  const i = path.lastIndexOf('\\');
  if (i < 0) {
    return '';
  }
  return i === 0 ? '' : path.substring(0, i);
}

/** 标记某目录内容已变化 */
export function markDirDirty(dir: string): void {
  dirtyDirs.add(dir);
}

/** 消费目录变更标记：命中返回 true 并清除，供列表页刷新用 */
export function consumeDirDirty(dir: string): boolean {
  if (dirtyDirs.has(dir)) {
    dirtyDirs.delete(dir);
    return true;
  }
  return false;
}
