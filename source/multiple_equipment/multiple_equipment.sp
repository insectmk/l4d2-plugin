/*
 * [L4D2] 多重装备 (multiple_equipment)
 * ============================================================================
 * 功能说明
 *   - 每个物品槽位（主武器 / 副武器 / 投掷物 / 医疗包 / 药丸·肾上腺素）
 *     可以额外保存一件备用物品。
 *   - 操作方式（只有一种模式）：
 *       1. 按任意槽位键（默认 1/2/3/4/5，对应游戏的 slot1~slot5）都完全按游戏
 *          原生逻辑切换到该槽位的物品，插件不会做任何跨槽位操作。
 *       2. 当玩家捡起同槽位的第二件物品时，被替换下来的旧物品会自动收进该槽位
 *          的备用槽（聊天框会有提示）。
 *          如果第二件物品与手持物品“完全相同”（医疗包、药丸、投掷物、近战武器），
 *          引擎原本会直接拒绝拾取，插件会接管这次拾取：旧物品进备用槽，新物品进背包。
 *       3. 在当前物品上再按一次同一个槽位键，就会和该槽位的备用物品互换。
 *   - 玩家改键后依然有效：插件识别的是“槽位”而不是物理按键。
 *   - 幸存者死亡时，除了引擎原生掉落手持物品外，插件会把备用物品也掉在尸体旁。
 *   - 战役过关切换章节时，备用物品保留。
 *
 * 参考实现
 *   	https://forums.alliedmods.net/showthread.php?t=166580
 * 		https://forums.alliedmods.net/showthread.php?p=2839724	
 *   （原作者 Pan Xiaohai & Marcus101RR，本插件为面向 L4D2 的重写版本）
 *
 * 与原参考实现的区别
 *   - 只用 OnPlayerRunCmd 的 weapon 参数做按键识别，不做每帧扫描，性能开销极低。
 *   - 只保留单一操作模式，去掉菜单、!sw 命令、Q 键模式、角色身上的备用模型。
 *   - 所有提示改为中文，并且只发送到聊天框。
 *   - 死亡时额外掉落全部备用物品（含弹药、弹匣、升级）。
 * ============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

// 玩家共有 5 个物品槽位：0=主武器 1=副武器 2=投掷物 3=医疗包 4=药丸/肾上腺素
#define MAX_SLOTS        5
// 保存物品名称的字符串长度
#define ITEM_LEN         64
// 近战武器在备用数据里的前缀，例如 "melee:fireaxe"
#define MELEE_PREFIX     "melee:"
#define MELEE_PREFIX_LEN 6
// 两次互换之间的最小间隔（秒），防止同一按键在极短时间内重复触发
#define SWAP_COOLDOWN 0.25
// 槽位“忙碌”时间（秒）：物品正在被使用/投掷的这段时间内禁止互换，
// 防止把正在扔出去的投掷物收进备用槽导致无限投掷物
#define SLOT_BUSY_TIME 1.5
// 备用物品存档文件（相对 addons/sourcemod/），按 SteamID 保存，
// 用于插件重载 / 玩家重连 / 换图后恢复备用物品
#define DATA_FILE "data/multiple_equipment.cfg"

// ---------------------------------------------------------------------------
// 每个玩家、每个槽位的备用物品数据
// ---------------------------------------------------------------------------
// 备用物品的“键”：
//   - 普通武器保存 classname，例如 "weapon_rifle_ak47"
//   - 近战武器保存 "melee:<近战脚本名>"，例如 "melee:fireaxe"
char g_sBackup[MAXPLAYERS + 1][MAX_SLOTS][ITEM_LEN];
int  g_iAmmo[MAXPLAYERS + 1][MAX_SLOTS];         // 主武器的备用弹药（m_iAmmo）
int  g_iClip[MAXPLAYERS + 1][MAX_SLOTS];         // 弹匣内子弹（m_iClip1）
int  g_iUpgrade[MAXPLAYERS + 1][MAX_SLOTS];      // 主武器升级位 / 副武器双持标记
int  g_iUpgradeAmmo[MAXPLAYERS + 1][MAX_SLOTS];  // 主武器已装填的升级弹药

// 上一次执行互换的时间，用于防止同一帧/极短时间内反复互换
float g_flLastSwap[MAXPLAYERS + 1];
// 每个槽位最近一次“开始使用/投掷”的时间。
// 在这段时间内禁止互换，避免把正在被消耗的物品复制进备用槽。
float g_flSlotBusy[MAXPLAYERS + 1][MAX_SLOTS];

// 缓存的 CTerrorPlayer::m_iAmmo 偏移，只在 OnPluginStart 计算一次
int g_iAmmoOffset = -1;

// classname -> m_iAmmo 数组下标
StringMap g_hAmmoType;
// classname / 近战键 -> 中文显示名
StringMap g_hNameZH;
// classname -> 武器所在槽位（用于判断“被替换下来的旧物品”属于哪个槽）
StringMap g_hSlotOf;

// 保留备用数据的截止时间。
// 正常过关切换章节后的一段时间内，round_start（可能触发多次）都不清空备用数据；
// 超过这个时间后的普通新回合才清空。
float g_flKeepUntil = 0.0;
// 上一张地图是否触发了正常的过关切换章节事件（map_transition）。
// 只有这种情况才保留备用物品；指令换图 / 新战役 / 非正常换图一律清空。
bool g_bChapterTransition = false;

public Plugin myinfo =
{
	name        = "multiple_equipment",
	author      = "InsectMk",
	description = "多重装备：每个槽位可额外携带一件备用物品，同一槽位键再按一次即可互换",
	version     = "1.0.0",
	url         = ""
};

// ===========================================================================
// 生命周期
// ===========================================================================

public void OnPluginStart()
{
	// m_iAmmo 是玩家实体上的一个 int 数组，用偏移 + 下标*4 读写备用弹药。
	// 只在这里查一次，避免参考实现那样每次读写都调用 FindSendPropInfo。
	g_iAmmoOffset = FindSendPropInfo("CTerrorPlayer", "m_iAmmo");

	// 插件在中途加载时也给出一个保留窗口，避免第一个 round_start 误清空
	g_flKeepUntil = GetGameTime() + 15.0;

	BuildItemMaps();

	HookEvent("player_death",   Event_PlayerDeath,   EventHookMode_Post);
	HookEvent("player_spawn",   Event_PlayerSpawn,   EventHookMode_Post);
	HookEvent("weapon_drop",    Event_WeaponDrop,    EventHookMode_Post);
	HookEvent("player_use",     Event_PlayerUse,     EventHookMode_Post);
	HookEvent("weapon_fire",    Event_WeaponFire,    EventHookMode_Post);
	HookEvent("heal_begin",     Event_HealBegin,     EventHookMode_Post);
	HookEvent("revive_begin",   Event_ReviveBegin,   EventHookMode_Post);
	HookEvent("round_start",    Event_RoundStart,    EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);
	HookEvent("finale_win",     Event_FinaleWin,     EventHookMode_PostNoCopy);
	HookEvent("mission_lost",   Event_MissionLost,   EventHookMode_PostNoCopy);

	// 插件在游戏中途被重载时，恢复当前在线玩家的备用物品
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			LoadClientFromFile(i);
		}
	}
}

public void OnPluginEnd()
{
	// 插件被卸载/重载前保存，避免换图时重载导致数据丢失
	SaveAllToFile();
}

public void OnClientPutInServer(int client)
{
	// 新连接的玩家（可能复用了刚断开玩家的下标）：先清干净，再从存档恢复。
	// 部分服务器换图时客户端会重连，这一步是跨章节保留备用物品的关键。
	ResetClient(client);
	LoadClientFromFile(client);
}

public void OnClientDisconnect(int client)
{
	// 玩家离开前先把当前备用物品写入存档（重连/换图重连后可以恢复）
	SaveClientToFile(client);
	ResetClient(client);
}

public void OnMapStart()
{
	// 区分两种换图：
	//   - 正常过关（旧地图触发过 map_transition）：保留备用物品；
	//   - 指令换图 / 新战役 / 非正常换图：全部清空，新地图从零开始。
	if (g_bChapterTransition)
	{
		g_bChapterTransition = false;

		// 新地图加载后的 15 秒内发生的 round_start 一律不清空
		//（L4D2 换图期间 round_start 可能触发多次，事件先后也不固定）。
		g_flKeepUntil = GetGameTime() + 15.0;
	}
	else
	{
		ClearAllState();
		g_flKeepUntil = 0.0;
		PrintToServer("[多重装备] 非过关换图，已清空全部备用物品状态");
	}
}

// ===========================================================================
// 事件
// ===========================================================================

/**
 * 幸存者死亡：把备用物品全部掉在尸体旁，然后清空该玩家的备用数据。
 * 手持物品由游戏引擎原生掉落，这里不重复处理，避免掉两份。
 */
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	// 死亡瞬间队伍仍然是 2（幸存者）
	if (GetClientTeam(client) == 2)
	{
		DropAllBackups(client);
	}

	ResetClient(client);

	// 把清空后的状态写回存档，避免重连/重载后把已经掉落的备用物品又恢复出来
	SaveClientToFile(client);
}

/**
 * 幸存者出生 / 复活：只重置互换冷却时间。
 * 备用数据要保留（战役换章节后玩家会重新出生，但备用物品应当还在）。
 */
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	// 新生命里的武器实体索引全部变了，清掉旧记录
	g_flLastSwap[client] = 0.0;
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		g_flSlotBusy[client][slot] = 0.0;
	}
}

/**
 * 玩家丢下一件武器。
 *
 * 这是“自动收藏备用物品”的入口：
 *   当玩家捡起同槽位的第二件物品时，引擎会先把旧物品丢到地上，
 *   然后触发本事件。这里先同步记录旧物品的完整状态（此时实体还在），
 *   再用 0.1 秒定时器判断这次丢弃是不是“被新物品替换”：
 *     - 槽位里已经出现另一件物品 → 说明是替换，把旧物品收进备用槽，
 *       并销毁地上的实体，避免出现可以捡起的复制品；
 *     - 槽位为空（玩家手动按 G 丢物品）→ 什么都不做，物品正常留在地上。
 */
public void Event_WeaponDrop(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidSurvivor(client))
	{
		return;
	}

	// propid 是被丢下武器的实体索引（L4D2 的 weapon_drop 事件字段）
	int dropped = event.GetInt("propid");
	if (dropped <= 0 || !IsValidEntity(dropped))
	{
		return;
	}

	// 判断这件物品属于哪个槽位；不归插件管理的物品直接忽略
	char classname[ITEM_LEN];
	GetEntityClassname(dropped, classname, sizeof(classname));

	int slot;
	if (!g_hSlotOf.GetValue(classname, slot))
	{
		return;
	}

	// 同步记录状态（实体这一帧仍然有效）
	int ammo, clip, upgrade, upgradeAmmo;
	ReadItemData(client, slot, dropped, ammo, clip, upgrade, upgradeAmmo);

	char key[ITEM_LEN];
	GetItemKey(dropped, key, sizeof(key));

	if (key[0] == '\0')
	{
		return;
	}

	// 用定时器延后判断“是被替换还是手动丢弃”
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(slot);
	pack.WriteCell(dropped);
	pack.WriteCell(ammo);
	pack.WriteCell(clip);
	pack.WriteCell(upgrade);
	pack.WriteCell(upgradeAmmo);
	pack.WriteString(key);
	CreateTimer(0.1, Timer_StoreDroppedItem, pack, TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * 判断刚才丢下的物品是否需要收进备用槽。
 */
public Action Timer_StoreDroppedItem(Handle timer, DataPack pack)
{
	pack.Reset();
	int userid = pack.ReadCell();
	int slot = pack.ReadCell();
	int dropped = pack.ReadCell();
	int ammo = pack.ReadCell();
	int clip = pack.ReadCell();
	int upgrade = pack.ReadCell();
	int upgradeAmmo = pack.ReadCell();

	char key[ITEM_LEN];
	pack.ReadString(key, sizeof(key));
	delete pack;

	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		// 玩家已经死亡：死亡流程会统一掉落备用物品，这里不再处理
		return Plugin_Stop;
	}

	int current = GetPlayerWeaponSlot(client, slot);

	// 槽位处于“使用/投掷”忙碌窗口：这次丢下的是正在被消耗的物品，
	// 无论槽位里当前是什么，都绝不能收进备用槽（否则会复制出无限投掷物）。
	// 只走补位流程。
	bool slotBusy = (g_flSlotBusy[client][slot] > 0.0
		&& GetGameTime() - g_flSlotBusy[client][slot] < SLOT_BUSY_TIME);

	// 情况一：槽位里出现了另一件物品 → 是“捡起新物品替换旧物品”
	if (!slotBusy && current > 0 && current != dropped)
	{
		// 备用槽已经有物品时不再收纳，避免覆盖玩家已有的备用物品
		if (g_sBackup[client][slot][0] != '\0')
		{
			return Plugin_Stop;
		}

		strcopy(g_sBackup[client][slot], ITEM_LEN, key);
		g_iAmmo[client][slot]        = ammo;
		g_iClip[client][slot]        = clip;
		g_iUpgrade[client][slot]     = upgrade;
		g_iUpgradeAmmo[client][slot] = upgradeAmmo;

		// 删掉地上的旧物品，避免同一件物品既在备用槽又在地上
		if (IsValidEntity(dropped))
		{
			AcceptEntityInput(dropped, "Kill");
		}

		char itemName[ITEM_LEN];
		GetDisplayName(key, itemName, sizeof(itemName));
		CPrintToChat(client, "{olive}[多重装备]{default} 备用 {lightgreen}%s{default}", itemName);

		return Plugin_Stop;
	}

	// 情况二：槽位变空 → 玩家使用或丢弃了这件物品
	// 先让游戏按自己的优先级把手上的武器切好（使用/丢弃动画结束后引擎会立刻切换），
	// 短暂等待后再静默补位，避免和引擎的切换动作抢在同一帧造成卡手感。
	g_flSlotBusy[client][slot] = GetGameTime();

	DataPack refillPack = new DataPack();
	refillPack.WriteCell(GetClientUserId(client));
	refillPack.WriteCell(slot);
	CreateTimer(0.4, Timer_RefillSlot, refillPack, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Stop;
}

/**
 * 玩家按下 +USE 使用了某个实体（可能是捡起地上的物品）。
 *
 * 为什么要监听这个事件：
 *   - 槽位 0（主武器）和槽位 1（近战 / 手枪双持）在捡同槽位物品时，引擎会自己
 *     完成换装并触发 weapon_drop，现有的“自动收藏备用物品”逻辑已经能处理。
 *   - 槽位 2/3/4（投掷物 / 医疗包 / 药丸）在槽位已有同类物品时，引擎会直接拒绝
 *     拾取，而且不会触发 weapon_drop，所以现有逻辑永远拿不到“第二件相同道具”。
 *   拾取成功时 item_pickup 先于 player_use 触发；拾取被拒绝时只有 player_use。
 *   因此这里只在“引擎拒绝的完全相同道具”这一种情况下接管，其他情况一律不处理。
 */
public void Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidSurvivor(client))
	{
		return;
	}

	// targetid 是被使用实体的 entindex（L4D2 的 player_use 事件字段）
	CaptureDuplicatePickup(client, event.GetInt("targetid"));
}

/**
 * 接管“同槽位再捡一件完全相同道具”的拾取。
 *
 * 引擎在槽位已有同类物品时会拒绝拾取，玩家只能先把旧物品丢到地上。
 * 这里把这次被拒绝的拾取改成一次“备用槽收纳”：
 *   旧物品 → 备用槽（保留弹药/弹匣/升级数据），地上的新物品 → 装进玩家背包。
 *
 * 与现有逻辑的边界（保证互不干扰）：
 *   - 拾取成功时 current == target（引擎把同一实体给了玩家），直接不处理；
 *   - 不同物品的换装由引擎触发 weapon_drop，走现有的 Timer_StoreDroppedItem，不处理；
 *   - 销毁旧物品用 RemovePlayerItem + Kill，与 SwapItem 相同，不会触发 weapon_drop，
 *     因此不会和现有收藏逻辑重复；
 *   - 备用槽已有物品时保持原行为：不接管（引擎照常拒绝拾取）。
 *
 * @param client 玩家
 * @param target 玩家按 E 使用的实体（地上物品的 entindex）
 * @return       true 表示本次拾取已被接管
 */
stock bool CaptureDuplicatePickup(int client, int target)
{
	// 目标必须是有效实体，并且是插件管理的物品（类名能查到槽位）
	if (target <= 0 || !IsValidEntity(target))
	{
		return false;
	}

	// 目标已经被玩家持有（拾取成功时引擎会把实体转给玩家），说明不需要接管。
	// 这一步同时兜住“引擎用新实体替代地上实体”的分支，避免把刚捡到的物品又收进备用槽。
	if (GetEntPropEnt(target, Prop_Send, "m_hOwnerEntity") == client)
	{
		return false;
	}

	char classname[ITEM_LEN];
	GetEntityClassname(target, classname, sizeof(classname));

	int slot;
	if (!g_hSlotOf.GetValue(classname, slot))
	{
		return false;
	}

	// 槽位过滤：
	//   - 0 主武器：引擎原生换装会触发 weapon_drop，现有逻辑已支持，不接管；
	//   - 1 只处理近战武器（weapon_melee）：手枪捡第二把是原生双持，电锯也不在本次范围内；
	//   - 2/3/4：正是引擎会拒绝同类拾取的槽位，需要接管。
	if (slot < 1 || slot > 4)
	{
		return false;
	}
	if (slot == 1 && !StrEqual(classname, "weapon_melee"))
	{
		return false;
	}

	// 物品正在被使用/投掷（忙碌窗口）内不接管，避免把正在消耗的物品复制进备用槽
	if (g_flSlotBusy[client][slot] > 0.0
		&& GetGameTime() - g_flSlotBusy[client][slot] < SLOT_BUSY_TIME)
	{
		return false;
	}

	int current = GetPlayerWeaponSlot(client, slot);

	// 槽位为空：引擎会正常拾取，不需要接管；
	// current == target：引擎已经把同一件物品给了玩家（拾取成功），同样不需要接管。
	if (current <= 0 || current == target)
	{
		return false;
	}

	// 备用槽已经有物品：保持现有行为（静默不处理，引擎的拒绝结果不变）
	if (g_sBackup[client][slot][0] != '\0')
	{
		return false;
	}

	// 只接管“完全相同”的物品：
	// 同槽位的不同物品（急救包 ↔ 电击器、燃烧瓶 ↔ 管状炸弹）引擎会自己换下旧物品，
	// 由 weapon_drop 的现有逻辑收藏；这里再处理会和那条路径重复。
	char curKey[ITEM_LEN];
	char targetKey[ITEM_LEN];
	GetItemKey(current, curKey, sizeof(curKey));
	GetItemKey(target, targetKey, sizeof(targetKey));

	if (curKey[0] == '\0' || !StrEqual(curKey, targetKey))
	{
		return false;
	}

	// 先读取手持物品的完整状态（这一帧实体仍然有效），再移除
	int ammo, clip, upgrade, upgradeAmmo;
	ReadItemData(client, slot, current, ammo, clip, upgrade, upgradeAmmo);

	// 拾取医疗包/药丸/投掷物时引擎不会切换手上的武器，
	// 所以先记下当前主动武器，装备完成后按需还原（与 RefillFromBackup 的处理一致）
	int prevActive = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

	// 直接移除并销毁手持物品：与 SwapItem 一样，不在原地留下可以再捡起的复制品。
	// RemovePlayerItem + Kill 不会触发 weapon_drop，不会和现有收藏逻辑重复。
	RemovePlayerItem(client, current);
	AcceptEntityInput(current, "Kill");

	// 把刚才换下来的旧物品收进备用槽
	strcopy(g_sBackup[client][slot], ITEM_LEN, curKey);
	g_iAmmo[client][slot]        = ammo;
	g_iClip[client][slot]        = clip;
	g_iUpgrade[client][slot]     = upgrade;
	g_iUpgradeAmmo[client][slot] = upgradeAmmo;

	// 直接把地上的同一实体装备给玩家：不新建实体，也就没有重复物品需要销毁
	EquipPlayerWeapon(client, target);

	// 投掷物数量为 0 会被游戏当成空物品（不显示/无法捡起/换手后消失），
	// 复用现有的数据写入函数保证至少为 1（其他槽位不受影响）
	if (slot == 2)
	{
		ApplyItemData(client, slot, target, 0, 1, 0, 0);
	}

	// 主动武器处理：
	//   - 被替换的正是手上拿着的物品 → 把主动武器指向新捡起的同一件物品，避免空手；
	//   - 只是背包里的槽位被替换 → 还原主动武器，保持与原生拾取一致的手感。
	if (prevActive == current)
	{
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", target);
	}
	else if (prevActive > 0 && IsValidEntity(prevActive)
		&& GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != prevActive)
	{
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", prevActive);

		// 只在真的发生切换时清掉“切换后攻击延迟”，避免出现动作僵硬/卡手
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime());
	}

	// 与 weapon_drop 收藏路径保持一致的聊天提示
	char itemName[ITEM_LEN];
	GetDisplayName(curKey, itemName, sizeof(itemName));
	CPrintToChat(client, "{olive}[多重装备]{default} 备用 {lightgreen}%s{default}", itemName);

	return true;
}

/**
 * 延迟补位：等游戏自己的切换动画结束后，再静默把备用物品放回槽位。
 */
public Action Timer_RefillSlot(Handle timer, DataPack pack)
{
	pack.Reset();
	int userid = pack.ReadCell();
	int slot = pack.ReadCell();
	delete pack;

	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}

	RefillIfEmpty(client, slot);
	return Plugin_Stop;
}

/**
 * 投掷物被扔出时，物品从背包消失，但 L4D2 不一定会触发 weapon_drop，
 * 所以额外监听 weapon_fire，延迟检查槽位 2 是否需要补位。
 */
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidSurvivor(client))
	{
		return;
	}

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));

	// 三种投掷物的 weapon_fire 名称
	if (!StrEqual(weapon, "molotov") && !StrEqual(weapon, "vomitjar") && !StrEqual(weapon, "pipe_bomb"))
	{
		return;
	}

	// 从投掷动作开始到投掷物真正离开背包的这段时间内，禁止槽位 2 互换。
	// 否则玩家在投掷瞬间按投掷物键，会把正在扔出去的投掷物收进备用槽，
	// 造成“备用物品变成刚扔出的投掷物”，可以无限投掷。
	g_flSlotBusy[client][2] = GetGameTime();

	// 等投掷动作完全结束、引擎切回优先级武器之后再检查（与参考插件 1.5 秒的等待一致；
	// 如果 weapon_drop 已经先触发补位，这里的检查会自动变成空操作）
	CreateTimer(1.5, Timer_RefillThrown, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * 投掷物扔出后的补位检查。
 */
public Action Timer_RefillThrown(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}

	RefillIfEmpty(client, 2);
	return Plugin_Stop;
}

/**
 * 开始用医疗包治疗：治疗动画期间禁止槽位 3 互换，
 * 避免把正在被消耗的医疗包复制进备用槽。
 */
public void Event_HealBegin(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidSurvivor(client))
	{
		return;
	}

	g_flSlotBusy[client][3] = GetGameTime();
}

/**
 * 开始使用电击器（L4D2 里电击器复活走 revive_begin）：复活动画期间禁止槽位 3 互换。
 * 普通手扶复活也会触发，但只是短暂禁止互换，没有副作用。
 */
public void Event_ReviveBegin(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidSurvivor(client))
	{
		return;
	}

	g_flSlotBusy[client][3] = GetGameTime();
}

/**
 * 如果槽位为空且存在备用物品，就把备用物品放回该槽位（补位）。
 * 不改变玩家当前手持的武器（近战武器除外，见 RefillFromBackup）。
 */
stock void RefillIfEmpty(int client, int slot)
{
	if (g_sBackup[client][slot][0] == '\0')
	{
		return;
	}
	if (GetPlayerWeaponSlot(client, slot) != -1)
	{
		return;
	}

	RefillFromBackup(client, slot);
}

/**
 * 把备用槽里的物品放回玩家的对应槽位。
 *
 * 性能 / 手感要点：
 *   - 调用方会在“使用/丢弃动作结束 + 引擎按优先级切好武器”之后才调用本函数，
 *     不会和引擎的切换动作抢同一帧。
 *   - 普通物品用 GivePlayerItem 只“放入背包”，不主动做装备切换，不播放收起/掏出动画。
 *   - 万一 GivePlayerItem 顺带把当前武器换掉了，只还原 m_hActiveWeapon 指针，
 *     不再调用 EquipPlayerWeapon 做第二次装备动画。
 */
stock void RefillFromBackup(int client, int slot)
{
	char key[ITEM_LEN];
	strcopy(key, sizeof(key), g_sBackup[client][slot]);
	if (key[0] == '\0')
	{
		return;
	}

	int prevActive = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int weapon;

	if (StrContains(key, MELEE_PREFIX, false) == 0)
	{
		// 近战武器：按脚本名创建实体，只能通过装备来加入背包（少数情况才会走到）
		weapon = CreateItemEntity(key);
		if (weapon <= 0)
		{
			return;
		}
		EquipPlayerWeapon(client, weapon);
	}
	else
	{
		// 普通物品：GivePlayerItem 只把物品放进对应槽位
		weapon = GivePlayerItem(client, key);
		if (weapon <= 0)
		{
			return;
		}
	}

	// 只有在当前武器真的被换掉时才还原指针；直接改指针不会播放装备动画
	if (prevActive > 0 && IsValidEntity(prevActive)
		&& GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != prevActive)
	{
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", prevActive);

		// 物品放入背包时引擎可能顺带设置了“切换后攻击延迟”，
		// 这里只在真的发生切换时清掉，避免出现动作僵硬/卡手
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime());
	}

	ApplyItemData(client, slot, weapon,
	              g_iAmmo[client][slot], g_iClip[client][slot],
	              g_iUpgrade[client][slot], g_iUpgradeAmmo[client][slot]);
	ClearSlotBackup(client, slot);

	char itemName[ITEM_LEN];
	GetDisplayName(key, itemName, sizeof(itemName));
	CPrintToChat(client, "{olive}[多重装备]{default} 补位 {lightgreen}%s{default}", itemName);
}

/**
 * 回合开始：
 *   - 新地图刚加载（或刚过关切换章节）的一段时间内：保留备用物品；
 *   - 其他情况（对抗新回合、mission_lost 重开等）：清空备用物品。
 *
 * 用“时间窗”而不是一次性标记，因为 L4D2 换图期间 round_start 可能触发不止一次，
 * 一次性标记被第一次消费后，后续 round_start 会误清空刚保留的数据。
 */
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (GetGameTime() < g_flKeepUntil)
	{
		return;
	}

	// 只在确实存在备用数据时打日志，方便服务器端确认清空时机
	if (AnyBackupData())
	{
		PrintToServer("[多重装备] 新回合开始，清空所有备用物品");
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	// 同步清空存档，避免重载/重连后恢复出上一回合的备用物品
	SaveAllToFile();
}

/**
 * 过关切换章节：延长保留窗口，覆盖地图加载较慢的情况。
 * 无论 GetGameTime 是否随地图重置，这个截止时间都能让新地图的 round_start 保留数据。
 * 同时把当前备用物品写盘，插件若在此刻被重载也能从存档恢复。
 */
public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	// 只有触发过这个事件的换图才是“正常过关换章节”，新地图才保留备用物品
	g_bChapterTransition = true;
	g_flKeepUntil = GetGameTime() + 120.0;
	SaveAllToFile();
}

/**
 * 战役通关：清空全部备用物品。
 * 否则上一局战役的备用物品会通过内存 / 存档带入下一局新战役。
 */
public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
	ClearAllState();
	PrintToServer("[多重装备] 战役通关，已清空全部备用物品状态");
}

/**
 * 战役失败（团灭/任务失败）：同样清空，重开时是干净状态。
 */
public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	ClearAllState();
	PrintToServer("[多重装备] 战役失败，已清空全部备用物品状态");
}

/**
 * 清空所有玩家的备用物品并删除存档文件。
 */
stock void ClearAllState()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	char path[PLATFORM_MAX_PATH];
	GetDataPath(path, sizeof(path));
	if (FileExists(path))
	{
		DeleteFile(path);
	}
}

/**
 * 是否还有任何玩家保存着备用物品（只在新回合清空前调用一次）。
 */
stock bool AnyBackupData()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		for (int slot = 0; slot < MAX_SLOTS; slot++)
		{
			if (g_sBackup[i][slot][0] != '\0')
			{
				return true;
			}
		}
	}
	return false;
}

// ===========================================================================
// 核心：按键识别与互换
// ===========================================================================

/**
 * 每帧、每个玩家都会调用。性能要求：必须让绝大多数帧在第一条判断就返回。
 *
 * weapon 参数的语义（见 sdktools_hooks.inc）：
 *   玩家切换武器时 = 新武器的实体索引；否则 = 0。
 * L4D2 里玩家按下槽位键时，客户端会把目标武器写进 usercmd 的 weaponselect，
 * 所以“同一个槽位键再按一次”也会让 weapon 等于同一把武器的实体索引。
 *
 * 判定规则（只处理“同一个槽位键再按一次”，其他按键完全交给引擎）：
 *   - weapon 对应的武器 == 玩家当前手上拿的武器 → 玩家按的是自己当前所在槽位
 *     的键，再按一次 → 与备用物品互换（没有备用就什么都不做）。
 *   - 其他情况 → 插件不干预，按键直接按游戏原生逻辑切换到对应槽位的物品。
 * 这样插件永远不会因为按 2/3/4/5 而去装备主武器槽位的东西。
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
	// 性能第一道闸门：没有切换武器就直接返回，常规帧只有这一次整数比较
	if (weapon <= 0)
	{
		return Plugin_Continue;
	}

	// 只处理存活的人类幸存者（机器人不参与，避免浪费性能）
	if (!IsValidSurvivor(client))
	{
		return Plugin_Continue;
	}

	// 倒地、挂边、被 Hunter/Smoker/Jockey/Charger 控制时不允许互换
	if (IsBusy(client))
	{
		return Plugin_Continue;
	}

	int slot = FindWeaponSlot(client, weapon);
	if (slot < 0)
	{
		return Plugin_Continue;
	}

	// 本次命令执行前玩家手上拿的武器（引擎要等本次 usercmd 处理完才会换武器）。
	// 只有“按下的键就是要切到当前已经在手上的这把武器”时才说明是同一个槽位键再次按下；
	// 按其他槽位键时 weapon 是另一把武器，两者不相等，插件完全不干预。
	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (activeWeapon != weapon)
	{
		return Plugin_Continue;
	}

	// 该槽位没有备用物品：什么都不做（绝不收起当前物品、绝不碰其他槽位）
	if (g_sBackup[client][slot][0] == '\0')
	{
		return Plugin_Continue;
	}

	// 物品正在被使用/投掷（例如投掷动作还没结束）时禁止互换，
	// 防止把正在消耗的投掷物复制进备用槽。
	// 时间戳为 0 表示从未使用过，直接跳过（避免地图刚加载的前 1.5 秒误判）
	if (g_flSlotBusy[client][slot] > 0.0
		&& GetGameTime() - g_flSlotBusy[client][slot] < SLOT_BUSY_TIME)
	{
		return Plugin_Continue;
	}

	// 防止同一按键在极短时间内重复触发互换
	if (GetGameTime() - g_flLastSwap[client] < SWAP_COOLDOWN)
	{
		return Plugin_Continue;
	}

	// 同一个槽位键又按了一次 → 只互换本槽位的当前物品与备用物品
	int newWeapon = SwapItem(client, slot, weapon);

	// 把 weapon 写成互换后的武器实体索引，让引擎在本次 usercmd 里直接选中新武器。
	// 不写的话，引擎可能还会去选已经被销毁的旧武器实体。
	weapon = newWeapon;

	return Plugin_Continue;
}

/**
 * 把当前物品与备用物品互换。
 *
 * @param client     玩家
 * @param slot       槽位（0~4）
 * @param oldWeapon  当前手上的武器实体
 * @return           互换后手上武器的实体索引；没有可换上的物品时返回 0
 */
stock int SwapItem(int client, int slot, int oldWeapon)
{
	// ---- 1) 读取当前物品的信息（名称、弹药、弹匣、升级） ----
	char oldKey[ITEM_LEN];
	GetItemKey(oldWeapon, oldKey, sizeof(oldKey));

	int oldAmmo, oldClip, oldUpgrade, oldUpgradeAmmo;
	ReadItemData(client, slot, oldWeapon, oldAmmo, oldClip, oldUpgrade, oldUpgradeAmmo);

	// ---- 2) 把当前物品从玩家身上移除并销毁 ----
	// 直接销毁而不是丢到地上，避免地上多出一份可以捡起的复制品。
	// 需要“收起”时，数据已经保存在 g_sBackup 里，不会丢失。
	RemovePlayerItem(client, oldWeapon);
	AcceptEntityInput(oldWeapon, "Kill");

	// ---- 3) 取出备用物品的数据，并先清空该备用槽 ----
	char newKey[ITEM_LEN];
	strcopy(newKey, sizeof(newKey), g_sBackup[client][slot]);
	int newAmmo        = g_iAmmo[client][slot];
	int newClip        = g_iClip[client][slot];
	int newUpgrade     = g_iUpgrade[client][slot];
	int newUpgradeAmmo = g_iUpgradeAmmo[client][slot];
	ClearSlotBackup(client, slot);

	// ---- 4) 有备用物品就创建实体并装备到玩家身上 ----
	int newWeapon = 0;
	if (newKey[0] != '\0')
	{
		newWeapon = CreateItemEntity(newKey);
		if (newWeapon > 0)
		{
			EquipPlayerWeapon(client, newWeapon);
			ApplyItemData(client, slot, newWeapon, newAmmo, newClip, newUpgrade, newUpgradeAmmo);
		}
	}

	// ---- 5) 把刚才收起的物品写入备用槽 ----
	if (oldKey[0] != '\0')
	{
		strcopy(g_sBackup[client][slot], ITEM_LEN, oldKey);
		g_iAmmo[client][slot]        = oldAmmo;
		g_iClip[client][slot]        = oldClip;
		g_iUpgrade[client][slot]     = oldUpgrade;
		g_iUpgradeAmmo[client][slot] = oldUpgradeAmmo;
	}

	// ---- 6) 记录互换时间并提示玩家 ----
	g_flLastSwap[client] = GetGameTime();
	NotifySwap(client, oldKey, newKey);

	return newWeapon;
}

/**
 * 幸存者死亡时，把全部备用物品生成在尸体位置。
 * 手持物品由引擎掉落，不在本函数处理。
 */
stock void DropAllBackups(int client)
{
	// 先快速判断有没有备用物品，没有就什么都不做
	bool hasBackup = false;
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		if (g_sBackup[client][slot][0] != '\0')
		{
			hasBackup = true;
			break;
		}
	}
	if (!hasBackup)
	{
		return;
	}

	float origin[3];
	GetClientEyePosition(client, origin);

	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		if (g_sBackup[client][slot][0] == '\0')
		{
			continue;
		}

		int weapon = CreateItemEntity(g_sBackup[client][slot]);
		if (weapon <= 0 || !IsValidEntity(weapon))
		{
			continue;
		}

		// 依次错开一点位置，避免多件物品叠在一起互相挤压
		origin[0] += 12.0;
		TeleportEntity(weapon, origin, NULL_VECTOR, NULL_VECTOR);
		ActivateEntity(weapon);

		// 弹匣与升级信息写在武器实体上
		if (HasEntProp(weapon, Prop_Send, "m_iClip1"))
		{
			// 投掷物数量不能是 0，否则掉在地上的投掷物会消失/捡不起来
			int useClip = g_iClip[client][slot];
			if (slot == 2 && useClip < 1)
			{
				useClip = 1;
			}
			SetEntProp(weapon, Prop_Send, "m_iClip1", useClip);
		}
		if (slot == 0)
		{
			if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
			{
				SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", g_iUpgrade[client][slot]);
			}
			if (HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
			{
				SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", g_iUpgradeAmmo[client][slot]);
			}
			// 掉在地上的主武器用 m_iExtraPrimaryAmmo 记录备用弹药，玩家捡起时一并带走
			if (HasEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo"))
			{
				SetEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo", g_iAmmo[client][slot]);
			}
		}
	}
}

// ===========================================================================
// 物品数据读写
// ===========================================================================

/**
 * 读取一件武器的状态数据。
 *
 * @param slot        槽位
 * @param weapon      武器实体
 * @param ammo        主武器备用弹药（m_iAmmo）
 * @param clip        弹匣内子弹（m_iClip1）
 * @param upgrade     主武器升级位 / 副武器双持标记
 * @param upgradeAmmo 主武器已装填的升级弹药
 */
stock void ReadItemData(int client, int slot, int weapon,
                        int &ammo, int &clip, int &upgrade, int &upgradeAmmo)
{
	ammo = 0;
	clip = 0;
	upgrade = 0;
	upgradeAmmo = 0;

	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return;
	}

	// 弹匣：所有 CBaseCombatWeapon 都有，但为了兼容第三方扩展仍先判断
	if (HasEntProp(weapon, Prop_Send, "m_iClip1"))
	{
		clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	}

	// 投掷物用 m_iClip1 记录数量。数量为 0 的投掷物会被游戏当成空物品
	// （不显示/无法捡起/换手后立刻消失），所以这里强制至少为 1。
	if (slot == 2 && clip < 1)
	{
		clip = 1;
	}

	if (slot == 0)
	{
		// 主武器：升级位、升级弹药、备用弹药
		if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
		{
			upgrade = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
		}
		if (HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
		{
			upgradeAmmo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
		}
		ammo = ReadReserveAmmo(client, weapon);
	}
	else if (slot == 1)
	{
		// 副武器：L4D2 手枪的双持状态。复用 upgrade 字段保存。
		// shortcut: 部分分支/自定义武器没有该属性，HasEntProp 判断失败时直接忽略双持状态。
		if (HasEntProp(weapon, Prop_Send, "m_hasDualWeapons"))
		{
			upgrade = GetEntProp(weapon, Prop_Send, "m_hasDualWeapons");
		}
	}
}

/**
 * 把保存下来的状态数据写回武器实体（以及玩家身上的备用弹药）。
 */
stock void ApplyItemData(int client, int slot, int weapon,
                         int ammo, int clip, int upgrade, int upgradeAmmo)
{
	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return;
	}

	if (HasEntProp(weapon, Prop_Send, "m_iClip1"))
	{
		// 投掷物数量不能是 0，否则会被当成空物品
		int useClip = (slot == 2 && clip < 1) ? 1 : clip;
		SetEntProp(weapon, Prop_Send, "m_iClip1", useClip);
	}

	if (slot == 0)
	{
		if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
		{
			SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", upgrade);
		}
		if (HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
		{
			SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", upgradeAmmo);
		}
		WriteReserveAmmo(client, weapon, ammo);
	}
	else if (slot == 1)
	{
		if (HasEntProp(weapon, Prop_Send, "m_hasDualWeapons"))
		{
			SetEntProp(weapon, Prop_Send, "m_hasDualWeapons", upgrade);
		}
	}
}

/**
 * 读取玩家身上某种弹药类型的备用弹药数量。
 * m_iAmmo 偏移已缓存，弹药类型下标由 g_hAmmoType 查表得到。
 */
stock int ReadReserveAmmo(int client, int weapon)
{
	if (g_iAmmoOffset <= 0)
	{
		return 0;
	}

	char classname[ITEM_LEN];
	GetEntityClassname(weapon, classname, sizeof(classname));

	int index;
	if (!g_hAmmoType.GetValue(classname, index))
	{
		return 0;
	}

	return GetEntData(client, g_iAmmoOffset + index * 4);
}

/**
 * 把备用弹药数量写回玩家身上的 m_iAmmo 对应位置。
 */
stock void WriteReserveAmmo(int client, int weapon, int ammo)
{
	if (g_iAmmoOffset <= 0)
	{
		return;
	}

	char classname[ITEM_LEN];
	GetEntityClassname(weapon, classname, sizeof(classname));

	int index;
	if (!g_hAmmoType.GetValue(classname, index))
	{
		return;
	}

	SetEntData(client, g_iAmmoOffset + index * 4, ammo);
}

// ===========================================================================
// 物品实体与名称
// ===========================================================================

/**
 * 根据备用数据创建物品实体。
 *   - "melee:xxx" → 创建 weapon_melee 并设置 melee_script_name
 *   - 其他         → 直接按 classname 创建
 */
stock int CreateItemEntity(const char[] key)
{
	if (key[0] == '\0')
	{
		return 0;
	}

	int weapon;

	if (StrContains(key, MELEE_PREFIX, false) == 0)
	{
		weapon = CreateEntityByName("weapon_melee");
		if (weapon <= 0)
		{
			return 0;
		}

		// key[MELEE_PREFIX_LEN] 就是去掉 "melee:" 前缀后的近战脚本名
		DispatchKeyValue(weapon, "melee_script_name", key[MELEE_PREFIX_LEN]);
	}
	else
	{
		weapon = CreateEntityByName(key);
		if (weapon <= 0)
		{
			return 0;
		}
	}

	DispatchSpawn(weapon);
	return weapon;
}

/**
 * 读取一件武器的“备用键”。
 * 普通武器直接取 classname；近战武器要记录具体型号（脚本名）。
 */
stock void GetItemKey(int weapon, char[] key, int len)
{
	key[0] = '\0';

	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return;
	}

	char classname[ITEM_LEN];
	GetEntityClassname(weapon, classname, sizeof(classname));

	if (StrEqual(classname, "weapon_melee"))
	{
		// 近战武器：优先读近战脚本名属性（m_strMapSetScriptName 就是 KeyValue
		// melee_script_name，自定义近战也能正确识别）
		char script[ITEM_LEN];
		script[0] = '\0';

		if (HasEntProp(weapon, Prop_Data, "m_strMapSetScriptName"))
		{
			GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", script, sizeof(script));
		}
		// 还没有就按模型路径反查内置近战表
		if (script[0] == '\0')
		{
			GetMeleeScriptFromModel(weapon, script, sizeof(script));
		}

		// shortcut: 完全无法识别型号的自定义近战时退回通用类名，
		//           换回后可能显示默认近战模型；如需完整支持，可在配置里维护模型表。
		if (script[0] == '\0')
		{
			strcopy(key, len, classname);
			return;
		}

		FormatEx(key, len, "%s%s", MELEE_PREFIX, script);
		return;
	}

	strcopy(key, len, classname);
}

/**
 * 用模型路径反查近战脚本名（内置近战表，参考原插件的 GetItemClass）。
 * 自定义近战通常能通过 m_strMeleeID 读到，这里的表只做兜底。
 */
stock void GetMeleeScriptFromModel(int weapon, char[] script, int len)
{
	script[0] = '\0';

	char model[128];
	GetEntPropString(weapon, Prop_Data, "m_ModelName", model, sizeof(model));

	// 注意顺序：cricket_bat 必须在 bat 之前判断，否则会被误判成棒球棍
	if      (StrContains(model, "fireaxe")         != -1) strcopy(script, len, "fireaxe");
	else if (StrContains(model, "electric_guitar") != -1) strcopy(script, len, "electric_guitar");
	else if (StrContains(model, "cricket_bat")     != -1) strcopy(script, len, "cricket_bat");
	else if (StrContains(model, "crowbar")         != -1) strcopy(script, len, "crowbar");
	else if (StrContains(model, "frying_pan")      != -1) strcopy(script, len, "frying_pan");
	else if (StrContains(model, "golfclub")        != -1) strcopy(script, len, "golfclub");
	else if (StrContains(model, "machete")         != -1) strcopy(script, len, "machete");
	else if (StrContains(model, "katana")          != -1) strcopy(script, len, "katana");
	else if (StrContains(model, "tonfa")           != -1) strcopy(script, len, "tonfa");
	else if (StrContains(model, "riotshield")      != -1) strcopy(script, len, "riotshield");
	else if (StrContains(model, "knife")           != -1) strcopy(script, len, "hunting_knife");
	else if (StrContains(model, "v_bat")           != -1) strcopy(script, len, "baseball_bat");
	else if (StrContains(model, "bat")             != -1) strcopy(script, len, "baseball_bat");
	else if (StrContains(model, "shovel")          != -1) strcopy(script, len, "shovel");
}

/**
 * 取物品的中文显示名；未知物品直接显示 classname / 备用键。
 */
stock void GetDisplayName(const char[] key, char[] out, int len)
{
	if (g_hNameZH.GetString(key, out, len))
	{
		return;
	}
	strcopy(out, len, key);
}

/**
 * 互换完成后的聊天提示（只发到聊天框，不用屏幕中央提示）。
 */
stock void NotifySwap(int client, const char[] oldKey, const char[] newKey)
{
	char oldName[ITEM_LEN];
	GetDisplayName(oldKey, oldName, sizeof(oldName));

	if (newKey[0] == '\0')
	{
		// 正常流程下不会走到这里（没有备用物品时不会触发互换），仅作兜底
		CPrintToChat(client,
			"{olive}[多重装备]{default} 收起 {lightgreen}%s{default}",
			oldName);
	}
	else
	{
		char newName[ITEM_LEN];
		GetDisplayName(newKey, newName, sizeof(newName));
		CPrintToChat(client,
			"{olive}[多重装备]{default} {lightgreen}%s{default} → {lightgreen}%s",
			oldName, newName);
	}
}

// ===========================================================================
// 状态查询
// ===========================================================================

/**
 * 是否是可参与互换的幸存者：人类、在游戏中、队伍 2、存活。
 */
stock bool IsValidSurvivor(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return false;
	}
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		return false;
	}
	if (GetClientTeam(client) != 2)
	{
		return false;
	}
	return IsPlayerAlive(client);
}

/**
 * 是否处于“不能换武器”的状态：倒地、挂边、被特感控制。
 * 只在按键切换帧调用，不会造成每帧开销。
 */
stock bool IsBusy(int client)
{
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) != 0)
	{
		return true;
	}
	if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1) != 0)
	{
		return true;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0)   // Hunter
	{
		return true;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0)      // Smoker
	{
		return true;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0)   // Charger
	{
		return true;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0)   // Jockey
	{
		return true;
	}
	return false;
}

/**
 * 找出某把武器属于哪个槽位；找不到返回 -1。
 */
stock int FindWeaponSlot(int client, int weapon)
{
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		if (GetPlayerWeaponSlot(client, slot) == weapon)
		{
			return slot;
		}
	}
	return -1;
}

// ===========================================================================
// 数据清理
// ===========================================================================

/**
 * 清空一个玩家的全部状态（断开连接、新回合、死亡后调用）。
 */
stock void ResetClient(int client)
{
	ResetBackup(client);
	g_flLastSwap[client] = 0.0;
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		g_flSlotBusy[client][slot] = 0.0;
	}
}

/**
 * 清空一个玩家的所有备用槽。
 */
stock void ResetBackup(int client)
{
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		ClearSlotBackup(client, slot);
	}
}

/**
 * 清空单个备用槽。
 */
stock void ClearSlotBackup(int client, int slot)
{
	g_sBackup[client][slot][0] = '\0';
	g_iAmmo[client][slot] = 0;
	g_iClip[client][slot] = 0;
	g_iUpgrade[client][slot] = 0;
	g_iUpgradeAmmo[client][slot] = 0;
}

// ===========================================================================
// 存档：跨地图 / 插件重载 / 玩家重连时保留备用物品
// ===========================================================================
// 只靠插件全局变量不够可靠：部分服务器换图会重连客户端，或换图时重载插件，
// 全局数组会被清零。这里参考 dual_primaries 的做法，把每个玩家的备用物品
// 按 SteamID 写入 KeyValues 存档，并在连接、插件重载时恢复。

/**
 * 存档路径：addons/sourcemod/data/multiple_equipment.cfg
 */
stock void GetDataPath(char[] path, int len)
{
	BuildPath(Path_SM, path, len, DATA_FILE);
}

/**
 * 保存单个玩家的备用物品。
 * 该玩家没有备用物品时会删除存档里对应的节。
 */
stock void SaveClientToFile(int client)
{
	if (client < 1 || client > MaxClients || IsFakeClient(client))
	{
		return;
	}

	char steamId[64];
	if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), false))
	{
		return;
	}

	char path[PLATFORM_MAX_PATH];
	GetDataPath(path, sizeof(path));

	KeyValues kv = new KeyValues("MultipleEquipment");
	if (FileExists(path))
	{
		kv.ImportFromFile(path);
	}

	// 先删除该玩家的旧数据
	if (kv.JumpToKey(steamId, false))
	{
		kv.GoBack();
		kv.DeleteKey(steamId);
	}

	// 检查是否还有备用物品
	bool hasBackup = false;
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		if (g_sBackup[client][slot][0] != '\0')
		{
			hasBackup = true;
			break;
		}
	}

	if (hasBackup)
	{
		kv.JumpToKey(steamId, true);

		for (int slot = 0; slot < MAX_SLOTS; slot++)
		{
			if (g_sBackup[client][slot][0] == '\0')
			{
				continue;
			}

			char slotName[8];
			FormatEx(slotName, sizeof(slotName), "%d", slot);

			kv.JumpToKey(slotName, true);
			kv.SetString("item", g_sBackup[client][slot]);
			kv.SetNum("ammo", g_iAmmo[client][slot]);
			kv.SetNum("clip", g_iClip[client][slot]);
			kv.SetNum("upgrade", g_iUpgrade[client][slot]);
			kv.SetNum("upgradeAmmo", g_iUpgradeAmmo[client][slot]);
			kv.GoBack();
		}

		kv.GoBack();
	}

	kv.Rewind();
	kv.ExportToFile(path);
	delete kv;
}

/**
 * 保存所有在线玩家（换图前、插件卸载前调用）。
 */
stock void SaveAllToFile()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			SaveClientToFile(i);
		}
	}
}

/**
 * 从存档恢复单个玩家的备用物品。
 * 调用方负责先重置该玩家的内存数据（OnClientPutInServer 已做）。
 */
stock void LoadClientFromFile(int client)
{
	if (client < 1 || client > MaxClients || IsFakeClient(client))
	{
		return;
	}

	char path[PLATFORM_MAX_PATH];
	GetDataPath(path, sizeof(path));
	if (!FileExists(path))
	{
		return;
	}

	char steamId[64];
	if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), false))
	{
		return;
	}

	KeyValues kv = new KeyValues("MultipleEquipment");
	if (!kv.ImportFromFile(path))
	{
		delete kv;
		return;
	}

	if (!kv.JumpToKey(steamId, false))
	{
		delete kv;
		return;
	}

	// 保证从干净状态开始读取
	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		ClearSlotBackup(client, slot);
	}

	for (int slot = 0; slot < MAX_SLOTS; slot++)
	{
		char slotName[8];
		FormatEx(slotName, sizeof(slotName), "%d", slot);

		if (!kv.JumpToKey(slotName, false))
		{
			continue;
		}

		char key[ITEM_LEN];
		key[0] = '\0';
		kv.GetString("item", key, sizeof(key));

		if (key[0] != '\0')
		{
			strcopy(g_sBackup[client][slot], ITEM_LEN, key);
			g_iAmmo[client][slot]        = kv.GetNum("ammo");
			g_iClip[client][slot]        = kv.GetNum("clip");
			g_iUpgrade[client][slot]     = kv.GetNum("upgrade");
			g_iUpgradeAmmo[client][slot] = kv.GetNum("upgradeAmmo");
		}

		kv.GoBack();
	}

	delete kv;
}

// ===========================================================================
// 初始化映射表
// ===========================================================================

/**
 * 一次性构建两张表：
 *   1. classname → m_iAmmo 数组下标（用于读写备用弹药）
 *   2. classname / 近战键 → 中文显示名（用于聊天提示）
 *
 * 全部用 StringMap，按键识别路径上不做长串 StrEqual 比较。
 */
stock void BuildItemMaps()
{
	g_hAmmoType = new StringMap();
	g_hNameZH  = new StringMap();
	g_hSlotOf  = new StringMap();

	// ---- classname → 槽位（用于 weapon_drop 时判断旧物品属于哪个槽）----
	// 槽位 0：主武器
	SetSlot("weapon_rifle",           0);
	SetSlot("weapon_rifle_sg552",     0);
	SetSlot("weapon_rifle_desert",    0);
	SetSlot("weapon_rifle_ak47",      0);
	SetSlot("weapon_rifle_m60",       0);
	SetSlot("weapon_smg",             0);
	SetSlot("weapon_smg_silenced",    0);
	SetSlot("weapon_smg_mp5",         0);
	SetSlot("weapon_pumpshotgun",     0);
	SetSlot("weapon_shotgun_chrome",  0);
	SetSlot("weapon_autoshotgun",     0);
	SetSlot("weapon_shotgun_spas",    0);
	SetSlot("weapon_hunting_rifle",   0);
	SetSlot("weapon_sniper_scout",    0);
	SetSlot("weapon_sniper_military", 0);
	SetSlot("weapon_sniper_awp",      0);
	SetSlot("weapon_grenade_launcher", 0);
	// 槽位 1：副武器（手枪 / 近战 / 电锯）
	SetSlot("weapon_pistol",        1);
	SetSlot("weapon_pistol_magnum", 1);
	SetSlot("weapon_melee",         1);
	SetSlot("weapon_chainsaw",      1);
	// 槽位 2：投掷物
	SetSlot("weapon_molotov",   2);
	SetSlot("weapon_pipe_bomb", 2);
	SetSlot("weapon_vomitjar",  2);
	// 槽位 3：医疗包 / 电击器 / 弹药包
	SetSlot("weapon_first_aid_kit",         3);
	SetSlot("weapon_defibrillator",         3);
	SetSlot("weapon_upgradepack_explosive", 3);
	SetSlot("weapon_upgradepack_incendiary", 3);
	// 槽位 4：药丸 / 肾上腺素
	SetSlot("weapon_pain_pills", 4);
	SetSlot("weapon_adrenaline", 4);

	// ---- m_iAmmo 数组下标（L4D2 固定表，下标 * 4 即为相对 m_iAmmo 的字节偏移）----
	SetAmmoType("weapon_rifle",          3);   // 步枪类
	SetAmmoType("weapon_rifle_sg552",    3);
	SetAmmoType("weapon_rifle_desert",   3);
	SetAmmoType("weapon_rifle_ak47",     3);
	SetAmmoType("weapon_rifle_m60",      3);
	SetAmmoType("weapon_smg",            5);   // 冲锋枪类
	SetAmmoType("weapon_smg_silenced",   5);
	SetAmmoType("weapon_smg_mp5",        5);
	SetAmmoType("weapon_pumpshotgun",    7);   // 泵动霰弹枪
	SetAmmoType("weapon_shotgun_chrome", 7);
	SetAmmoType("weapon_autoshotgun",    8);   // 自动霰弹枪
	SetAmmoType("weapon_shotgun_spas",   8);
	SetAmmoType("weapon_hunting_rifle",  9);   // 猎枪
	SetAmmoType("weapon_sniper_scout",   10);  // 狙击枪类
	SetAmmoType("weapon_sniper_military",10);
	SetAmmoType("weapon_sniper_awp",     10);
	SetAmmoType("weapon_grenade_launcher", 17); // 榴弹发射器

	// ---- 中文显示名：主武器 ----
	SetName("weapon_rifle",            "M16A4 步枪");
	SetName("weapon_rifle_sg552",      "SG552 步枪");
	SetName("weapon_rifle_desert",     "沙漠步枪");
	SetName("weapon_rifle_ak47",       "AK-47 步枪");
	SetName("weapon_rifle_m60",        "M60 机枪");
	SetName("weapon_smg",              "乌兹冲锋枪");
	SetName("weapon_smg_silenced",     "消音冲锋枪");
	SetName("weapon_smg_mp5",          "MP5 冲锋枪");
	SetName("weapon_pumpshotgun",      "泵动霰弹枪");
	SetName("weapon_shotgun_chrome",   "铬合金霰弹枪");
	SetName("weapon_autoshotgun",      "战斗霰弹枪");
	SetName("weapon_shotgun_spas",     "SPAS-12 霰弹枪");
	SetName("weapon_hunting_rifle",    "猎枪");
	SetName("weapon_sniper_scout",     "Scout 狙击枪");
	SetName("weapon_sniper_military",  "军用狙击枪");
	SetName("weapon_sniper_awp",       "AWP 狙击枪");
	SetName("weapon_grenade_launcher", "榴弹发射器");

	// ---- 中文显示名：副武器 ----
	SetName("weapon_pistol",        "手枪");
	SetName("weapon_pistol_magnum", "马格南手枪");
	SetName("weapon_chainsaw",      "电锯");

	// ---- 中文显示名：近战（键带 melee: 前缀）----
	SetName("melee:fireaxe",         "消防斧");
	SetName("melee:baseball_bat",    "棒球棍");
	SetName("melee:crowbar",         "撬棍");
	SetName("melee:electric_guitar", "电吉他");
	SetName("melee:cricket_bat",     "板球拍");
	SetName("melee:frying_pan",      "平底锅");
	SetName("melee:golfclub",        "高尔夫球杆");
	SetName("melee:machete",         "砍刀");
	SetName("melee:katana",          "武士刀");
	SetName("melee:tonfa",           "警棍");
	SetName("melee:riotshield",      "防暴盾");
	SetName("melee:hunting_knife",   "猎刀");
	SetName("melee:shovel",          "铁铲");

	// ---- 中文显示名：投掷物 ----
	SetName("weapon_molotov",   "燃烧瓶");
	SetName("weapon_pipe_bomb", "管状炸弹");
	SetName("weapon_vomitjar",  "胆汁瓶");

	// ---- 中文显示名：医疗包槽 ----
	SetName("weapon_first_aid_kit",         "急救包");
	SetName("weapon_defibrillator",         "电击器");
	SetName("weapon_upgradepack_explosive", "高爆弹药包");
	SetName("weapon_upgradepack_incendiary","燃烧弹药包");

	// ---- 中文显示名：药丸 / 肾上腺素槽 ----
	SetName("weapon_pain_pills", "止痛药");
	SetName("weapon_adrenaline", "肾上腺素");
}

stock void SetAmmoType(const char[] classname, int index)
{
	g_hAmmoType.SetValue(classname, index);
}

stock void SetName(const char[] key, const char[] name)
{
	g_hNameZH.SetString(key, name);
}

stock void SetSlot(const char[] classname, int slot)
{
	g_hSlotOf.SetValue(classname, slot);
}
