import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SmbConfig } from '../model/SmbConfig';
import { ShareEntry } from '../model/ShareEntry';
import { NeighborHost } from '../model/NeighborHost';

const PREFS_NAME = 'nasplayer_config';

export interface Credentials {
  username: string;
  password: string;
}

interface ShareCacheItem {
  name: string;
  type: number;
  remark: string;
}

interface HostCacheItem {
  ip: string;
  dialect: number;
}

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

  static async saveCredentials(context: common.UIAbilityContext, username: string,
    password: string): Promise<void> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    store.putSync('username', username);
    store.putSync('password', password);
    await store.flush();
  }

  static async loadCredentials(context: common.UIAbilityContext): Promise<Credentials> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const cred: Credentials = {
      username: store.getSync('username', '') as string,
      password: store.getSync('password', '') as string
    };
    return cred;
  }

  static async saveShares(context: common.UIAbilityContext, host: string,
    shares: ShareEntry[]): Promise<void> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const items: ShareCacheItem[] = [];
    for (let i = 0; i < shares.length; i++) {
      const s = shares[i];
      const item: ShareCacheItem = {
        name: s.name,
        type: s.type,
        remark: s.remark
      };
      items.push(item);
    }
    store.putSync('shares_' + host, JSON.stringify(items));
    await store.flush();
  }

  static async loadShares(context: common.UIAbilityContext, host: string): Promise<ShareEntry[]> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const raw = store.getSync('shares_' + host, '') as string;
    const out: ShareEntry[] = [];
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as object;
      if (parsed instanceof Array) {
        for (let i = 0; i < parsed.length; i++) {
          const item = parsed[i] as ShareCacheItem;
          if (item !== undefined && item !== null && typeof item.name === 'string') {
            out.push(ShareEntry.of(item.name, item.type, item.remark));
          }
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }

  static async saveHosts(context: common.UIAbilityContext, hosts: NeighborHost[]): Promise<void> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const items: HostCacheItem[] = [];
    for (let i = 0; i < hosts.length; i++) {
      const h = hosts[i];
      const item: HostCacheItem = {
        ip: h.ip,
        dialect: h.dialect
      };
      items.push(item);
    }
    store.putSync('hosts', JSON.stringify(items));
    await store.flush();
  }

  static async loadHosts(context: common.UIAbilityContext): Promise<NeighborHost[]> {
    const store = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    const raw = store.getSync('hosts', '') as string;
    const out: NeighborHost[] = [];
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as object;
      if (parsed instanceof Array) {
        for (let i = 0; i < parsed.length; i++) {
          const item = parsed[i] as HostCacheItem;
          if (item !== undefined && item !== null && typeof item.ip === 'string' && item.ip.length > 0) {
            out.push(NeighborHost.of(item.ip, item.dialect));
          }
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }
}
