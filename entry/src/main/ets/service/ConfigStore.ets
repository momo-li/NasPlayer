import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SmbConfig } from '../model/SmbConfig';

const PREFS_NAME = 'nasplayer_config';

export class ConfigStore {
  static async load(context: common.UIAbilityContext): Promise<SmbConfig> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const cfg: SmbConfig = {
      host: store.getSync('host', '') as string,
      port: store.getSync('port', 445) as number,
      share: store.getSync('share', '') as string,
      username: store.getSync('username', '') as string,
      password: store.getSync('password', '') as string,
      domain: store.getSync('domain', 'WORKGROUP') as string
    };
    return cfg;
  }

  static async save(context: common.UIAbilityContext, cfg: SmbConfig): Promise<void> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    store.putSync('host', cfg.host);
    store.putSync('port', cfg.port);
    store.putSync('share', cfg.share);
    store.putSync('username', cfg.username);
    store.putSync('password', cfg.password);
    store.putSync('domain', cfg.domain);
    await store.flush();
  }
}
