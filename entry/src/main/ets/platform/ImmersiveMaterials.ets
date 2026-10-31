import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';

/** ArkUI 材质从 API 26 起可用；HDS 材质按自身的 API 23 契约独立判断。 */
export class ImmersiveMaterials {
  /** API 26：硬件支持由 ArkUI 自身判断，不借用 HDS 类型列表推断。 */
  static get supported(): boolean {
    if (deviceInfo.apiAvailable('26.0.0')) { return uiMaterial.isImmersiveMaterialSupported(); }
    return false;
  }

  /** API 26：动态图片上方的常驻操作面不参与实时折射。 */
  static get PLAIN(): uiMaterial.Material | undefined {
    if (deviceInfo.apiAvailable('26.0.0')) { return uiMaterial.Material.empty; }
    return undefined;
  }

  /** API 26：反色只用于足够薄的标题操作材质。 */
  static get TITLE_BAR_ACTION(): uiMaterial.Material | undefined {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          colorInvert: true, interactive: true, lightEffect: {} });
      }
      return uiMaterial.Material.empty;
    }
    return undefined;
  }

  /** API 26：底栏常驻层保留较高的背景透出比例。 */
  static get FLOATING_BAR_THIN(): uiMaterial.Material | undefined {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN, interactive: true });
      }
      return uiMaterial.Material.empty;
    }
    return undefined;
  }

  /** API 26：菜单优先保证文字可读性，不启用厚材质反色。 */
  static get POPUP_MENU_THICK(): uiMaterial.Material | undefined {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK, interactive: true, lightEffect: {} });
      }
      return uiMaterial.Material.empty;
    }
    return undefined;
  }

  /** API 26：长内容半模态通过最厚档隔离底层画面。 */
  static get SHEET_ULTRA_THICK(): uiMaterial.Material | undefined {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
      }
      return uiMaterial.Material.empty;
    }
    return undefined;
  }

  /** HDS 6.1.0(23)：将设备能力分档交给 HDS，保持两套材质枚举独立。 */
  static get HDS_ADAPTIVE_EFFECT(): SystemMaterialParams | undefined {
    if (deviceInfo.apiAvailable('6.1.0(23)')) {
      return { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE };
    }
    return undefined;
  }
}
