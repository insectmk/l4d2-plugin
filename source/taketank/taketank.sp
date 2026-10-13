#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>
#include <multicolors>

/*
 * [L4D2]接管坦克 - 本地 fork 版
 * ------------------------------------------------------------
 * 原作者:        NanakaNeko
 * 原仓库:        https://github.com/NanakaNeko/l4d2_plugins_coop/blob/main/scripting/taketank.sp
 * 原 license:    GPLv3
 * 上游 commit/tag: Commit bfe7ab5
 *
 * 本 fork 的修改点:
 *   - 2026-10: 增加 AutoExecConfig 自动生成 addons/cfg/sourcemod/taketank.cfg
 *   - 2026-10: 增加接管者击倒/击杀幸存者的回血配置 + 公屏信息美化（multicolors）
 *   - 2026-10: 增加接管者 Tank 被击杀后的处理模式（直接死亡/复活接管/复活倒地）
 *
 * 同步策略:      硬分叉
 * 是否已向上游 PR: 否
 * Bug 反馈:      本仓库 issues
 *
 * Fork 维护者:   InsectMk
 * Fork 时间:     2026-10-13
 * 本 fork license: GPLv3
 */

#define GAMEDATA "taketank"

ConVar
	cv_PbEnable,
	cv_HealOnDown,
	cv_HealOnKill,
	cv_DeathHandling;

bool
	IsPlayerPB[MAXPLAYERS + 1],
	TankBot[MAXPLAYERS + 1],
	g_bIsTankTaker[MAXPLAYERS + 1];

Address g_pStatsCondition;
bool    g_bStatsPatched;

public Plugin myinfo =
{
	name = "[L4D2]接管坦克",
	description = "L4D2 take tank,use in coop mode",
	author = "奈",
	version = "1.3.0",
	url = "https://github.com/NanakaNeko/l4d2_plugins_coop"
};

public void OnPluginStart()
{
	// ① 创建 ConVar
	cv_PbEnable       = CreateConVar("l4d2_take_tank_enable",        "1", "开关pb接管 开启:1 关闭:0", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_HealOnDown     = CreateConVar("l4d2_take_tank_heal_on_down",   "0", "接管者击倒幸存者回血量。0=不回血;0<x<1=基于最大血量百分比;x>=1=固定血量。仅对接管人控制的Tank生效。", FCVAR_NOTIFY);
	cv_HealOnKill     = CreateConVar("l4d2_take_tank_heal_on_kill",   "0", "接管者击杀幸存者回血量(规则同上)。", FCVAR_NOTIFY);
	cv_DeathHandling  = CreateConVar("l4d2_take_tank_death_handling", "0", "接管者Tank被击杀后处理。0=直接死亡;1=复活接管原幸存者bot(找不到bot直接复活);2=复活接管后倒地。", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	HookConVarChange(cv_PbEnable, CvarChange);

	// ② 注册命令
	RegAdminCmd("sm_tt", TakeTank, ADMFLAG_ROOT, "接管AI坦克");
	RegConsoleCmd("sm_pb", PanBian, "接管坦克预选池");

	// ③ 注册事件
	HookEvent("player_spawn",         Event_PlayerSpawn);
	HookEvent("tank_frustrated",      Event_TankFrustrated);
	HookEvent("player_bot_replace",   Event_PlayerBotReplace);
	HookEvent("player_death",         Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_incapacitated", Event_PlayerIncapacitated);

	HookEvent("round_start",    Event_Reset, EventHookMode_PostNoCopy);
	HookEvent("round_end",      Event_Reset, EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_Reset, EventHookMode_PostNoCopy);
	HookEvent("mission_lost",   Event_Reset, EventHookMode_PostNoCopy);

	// ④ 初始化 gamedata（用于 StatsConditionPatch）
	InitGameData();

	// ⑤ 必须放在所有 CreateConVar 之后，自动生成 addons/cfg/sourcemod/taketank.cfg
	AutoExecConfig(true, "taketank", "sourcemod");
}

public void CvarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	reset();
}

void Event_Reset(Event event, const char[] name, bool dontBroadcast)
{
	reset();
}

public void OnMapEnd()
{
	reset();
}

public void OnClientDisconnect(int client)
{
	IsPlayerPB[client]      = false;
	g_bIsTankTaker[client]  = false;
}

void reset()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 3 && GetEntProp(client, Prop_Send, "m_zombieClass") == 8)
			ChangeClientTeamToSurvivor(client);
		IsPlayerPB[client]     = false;
		g_bIsTankTaker[client] = false;
	}
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return;

	TankBot[client]     = false;
	g_bIsTankTaker[client] = false;
	RequestFrame(NextFrame_PlayerSpawn, userid); // player_bot_replace在player_spawn之后触发, 延迟一帧进行接管判断
}

void NextFrame_PlayerSpawn(int client)
{
	if (!(client = GetClientOfUserId(client)) || !IsClientInGame(client) || IsClientInKickQueue(client) || !IsPlayerAlive(client))
		return;

	if (TankBot[client])
		return;

	if (IsFakeClient(client) && GetClientTeam(client) == 3 && GetEntProp(client, Prop_Send, "m_zombieClass") == 8)
		TakeOverTank(client);
}

void Event_TankFrustrated(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsFakeClient(client))
		return;

	RequestFrame(NextFrame_ForceChangeTeamSurvivor, GetClientUserId(client));
}

void NextFrame_ForceChangeTeamSurvivor(int client)
{
	if (!(client = GetClientOfUserId(client)) || !IsClientInGame(client))
		return;

	g_bIsTankTaker[client] = false;
	ChangeClientTeamToSurvivor(client);
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	int bot    = GetClientOfUserId(event.GetInt("bot"));
	int player = GetClientOfUserId(event.GetInt("player"));

	if (GetClientTeam(bot) == 3 && GetEntProp(bot, Prop_Send, "m_zombieClass") == 8)
	{
		if (!IsFakeClient(player))
			TankBot[player] = true; // 主动或被动放弃Tank控制权(BOT替换玩家)

		SetEntProp(bot, Prop_Data, "m_iHealth", GetEntProp(player, Prop_Data, "m_iHealth"));
		SetEntProp(bot, Prop_Data, "m_iMaxHealth", GetEntProp(player, Prop_Data, "m_iMaxHealth"));
	}

	// 接管者把 Tank 交还 bot，清除接管者标识
	if (player && g_bIsTankTaker[player])
	{
		g_bIsTankTaker[player] = false;
		if (bot) g_bIsTankTaker[bot] = false; // 同一 entity slot 安全清理
	}
}

void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	ApplyHealOnAction(attacker, victim, cv_HealOnDown.FloatValue, "击倒");
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!victim || !IsClientInGame(victim))
		return;

	// —— A. 接管者 Tank 被击杀 ——
	if (g_bIsTankTaker[victim]
		&& !IsFakeClient(victim)
		&& GetClientTeam(victim) == 3
		&& GetEntProp(victim, Prop_Send, "m_zombieClass") == 8)
	{
		int mode = cv_DeathHandling.IntValue;

		// 立即广播（双阵营）
		switch (mode)
		{
			case 0:
				CPrintToChatAll("{orange}[坦克]{olive}%N {default}的坦克倒下了，{red}接管者阵亡{default}。", victim);
			case 1:
				CPrintToChatAll("{orange}[坦克]{olive}%N {default}的坦克倒下了，{green}复活接管原幸存者 bot{default}。", victim);
			case 2:
				CPrintToChatAll("{orange}[坦克]{olive}%N {default}的坦克倒下了，{green}复活接管原幸存者 bot{default}并{red}倒地{default}。", victim);
		}

		if (mode == 0)
		{
			ChangeClientTeamToSurvivor(victim); // 已包含 g_bIsTankTaker 清理
			return;
		}

		// mode 1/2: 延迟一帧再 respawn（Pre 事件中直接 respawn 会被游戏拒绝）
		// 同时记录 Tank 死亡位置，复活后传送过去
		float vDeathPos[3];
		GetClientAbsOrigin(victim, vDeathPos);

		DataPack dPack = new DataPack();
		dPack.WriteCell(GetClientUserId(victim));
		dPack.WriteCell(mode);
		dPack.WriteFloat(vDeathPos[0]);
		dPack.WriteFloat(vDeathPos[1]);
		dPack.WriteFloat(vDeathPos[2]);
		RequestFrame(NextFrame_RespawnTaker, dPack);
		return;
	}

	// —— B. 原 BOT Tank 死亡或非接管者 Tank 死亡:旧逻辑接管者回幸存者阵营 ——
	if (!IsFakeClient(victim) && GetClientTeam(victim) == 3 && GetEntProp(victim, Prop_Send, "m_zombieClass") == 8)
	{
		ChangeClientTeamToSurvivor(victim);
		return;
	}

	// —— C. 幸存者被接管者 Tank 击杀 ——
	if (attacker && IsClientInGame(attacker) && GetClientTeam(victim) == 2)
	{
		ApplyHealOnAction(attacker, victim, cv_HealOnKill.FloatValue, "击杀");
	}
}

void NextFrame_RespawnTaker(DataPack dPack)
{
	dPack.Reset();
	int userid = dPack.ReadCell();
	int mode   = dPack.ReadCell();
	float vDeathPos[3];
	vDeathPos[0] = dPack.ReadFloat();
	vDeathPos[1] = dPack.ReadFloat();
	vDeathPos[2] = dPack.ReadFloat();
	delete dPack;

	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || IsClientInKickQueue(client))
		return;

	// 旁观（让原 bot 重新挂载 client 为 idle spectator）
	ChangeClientTeam(client, 1);

	// 优先接管 idle 中的原幸存者 bot
	int bot = GetBotOfIdlePlayer(client);
	if (bot && IsClientInGame(bot) && IsPlayerAlive(bot))
	{
		L4D_TakeOverBot(client);
	}
	else
	{
		// 找不到原 bot，先切到 team 2 再 respawn（L4D_RespawnPlayer 在 team 2 上更可靠）
		ChangeClientTeam(client, 2);
		StatsConditionPatch(true);
		L4D_RespawnPlayer(client, true);
		StatsConditionPatch(false);
	}

	// 传送回 Tank 死亡位置（用户要求）
	if (IsPlayerAlive(client))
	{
		TeleportEntity(client, vDeathPos, NULL_VECTOR, NULL_VECTOR);
	}

	// 选项 2: 延迟一帧强制倒地（等 respawn/takeover 完成）
	if (mode == 2)
	{
		RequestFrame(NextFrame_IncapTaker, GetClientUserId(client));
	}

	g_bIsTankTaker[client] = false;
}

void NextFrame_IncapTaker(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	IncapTaker(client);
	CPrintToChatAll("{orange}[坦克]{olive}%N {red}倒地{default}，需要其他幸存者救援！", client);
}

Action TakeTank(int client, int args)
{
	int tank;
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Handled;
	if (GetClientTeam(client) == 3 && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == 8)
	{
		CPrintToChat(client, "{green}[提示]{lightgreen}你当前已经是坦克了。");
		return Plugin_Handled;
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_zombieClass") == 8)
		{
			tank = i;
			break;
		}
	}
	if (!tank)
	{
		CPrintToChat(client, "{green}[提示]{lightgreen}无可供接管的坦克存在。");
		return Plugin_Handled;
	}
	if (GetClientTeam(client) == 2 || GetClientTeam(client) == 1)
	{
		int m_iHealth = GetEntProp(tank, Prop_Data, "m_iHealth");
		int m_iMaxHealth = GetEntProp(tank, Prop_Data, "m_iMaxHealth");
		ChangeClientTeam(client, 3);
		L4D_TakeOverZombieBot(client, tank);
		SetEntProp(client, Prop_Data, "m_iHealth", m_iHealth);
		SetEntProp(client, Prop_Data, "m_iMaxHealth", m_iMaxHealth);

		g_bIsTankTaker[client] = true;
		CPrintToChatAll("{green}[接管]{olive}%N {default}接管了坦克！", client);
	}
	return Plugin_Handled;
}

Action PanBian(int client, int args)
{
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Handled;
	if (!cv_PbEnable.BoolValue)
	{
		CPrintToChat(client, "{green}[提示]{red}叛变抽取坦克已关闭。");
		return Plugin_Handled;
	}

	if (!IsPlayerPB[client])
	{
		IsPlayerPB[client] = true;
		CPrintToChat(client, "{green}[叛变]{lightgreen}已加入叛变列表");
		CPrintToChat(client, "{green}[叛变]{lightgreen}再次输入该指令可退出叛变列表");
		CPrintToChat(client, "{green}[叛变]{lightgreen}坦克出现后将会随机从叛变列表中抽取 1 人接管");
		CPrintToChat(client, "{green}[叛变]{olive}当前叛变玩家列表:");

		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsPlayerPB[i] && IsClientInGame(i) && !IsFakeClient(i))
				CPrintToChat(client, "{olive}-> {lightgreen}%N", i);
		}
	}
	else
	{
		IsPlayerPB[client] = false;
		CPrintToChat(client, "{green}[叛变]{lightgreen}已退出叛变列表");
	}

	return Plugin_Handled;
}

int GetPBPlayer()
{
	int client = 1;
	ArrayList aClients = new ArrayList();

	for (; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client))
			continue;

		if (GetClientTeam(client) == 2 && IsPlayerPB[client])
			aClients.Push(client);
	}

	if (!aClients.Length)
		client = 0;
	else
		client = aClients.Get(Math_GetRandomInt(0, aClients.Length - 1));

	delete aClients;
	return client;
}

// https://github.com/bcserv/smlib/blob/2c14acb85314e25007f5a61789833b243e7d0cab/scripting/include/smlib/math.inc#L144-L163
#define SIZE_OF_INT 2147483647 // without 0
int Math_GetRandomInt(int min, int max)
{
	int random = GetURandomInt();
	if (random == 0)
		random++;

	return RoundToCeil(float(random) / (float(SIZE_OF_INT) / float(max - min + 1))) + min - 1;
}

int TakeOverTank(int tank)
{
	int client = GetPBPlayer();
	if (!client)
		return 0;

	if (IsClientInGame(tank) && IsFakeClient(tank) && GetClientTeam(client) == 2)
	{
		int m_iHealth = GetEntProp(tank, Prop_Data, "m_iHealth");
		int m_iMaxHealth = GetEntProp(tank, Prop_Data, "m_iMaxHealth");
		ChangeClientTeam(client, 3);
		L4D_TakeOverZombieBot(client, tank);
		SetEntProp(client, Prop_Data, "m_iHealth", m_iHealth);
		SetEntProp(client, Prop_Data, "m_iMaxHealth", m_iMaxHealth);

		g_bIsTankTaker[client] = true;
		CPrintToChatAll("{green}[接管]{olive}%N {default}接管了坦克！", client);
		return client;
	}

	return 0;
}

void ChangeClientTeamToSurvivor(int client)
{
	g_bIsTankTaker[client] = false;
	ChangeClientTeam(client, 2);
	if (IsPlayerAlive(client))
		ForcePlayerSuicide(client);
}

// =============================================================================
//                              回血逻辑
// =============================================================================
void ApplyHealOnAction(int attacker, int victim, float cvarValue, const char[] tag)
{
	if (!attacker || !victim)
		return;
	if (!IsClientInGame(attacker) || !IsPlayerAlive(attacker))
		return;
	if (GetClientTeam(victim) != 2)
		return;
	// 仅对人类接管者控制的 Tank 生效（对原 BOT Tank 无效）
	if (IsFakeClient(attacker) || !g_bIsTankTaker[attacker])
		return;
	if (GetClientTeam(attacker) != 3 || GetEntProp(attacker, Prop_Send, "m_zombieClass") != 8)
		return;

	if (cvarValue <= 0.0)
		return; // 关闭回血，不广播

	int curHp  = GetEntProp(attacker, Prop_Data, "m_iHealth");
	int maxHp  = GetEntProp(attacker, Prop_Data, "m_iMaxHealth");
	int amount = (cvarValue < 1.0)
		? RoundToCeil(cvarValue * float(maxHp)) // 百分比
		: RoundToCeil(cvarValue);                // 固定血量

	int newHp = curHp + amount;
	if (newHp > maxHp) newHp = maxHp;
	if (newHp == curHp)
		return; // 已满血，跳过广播

	SetEntProp(attacker, Prop_Data, "m_iHealth", newHp);

	// 双阵营广播
	CPrintToChatAll("{green}[坦克]{olive}%N {default}%s了 {olive}%N{default}，回复 {olive}%d {default}点血量（{lightgreen}%d{olive}/{lightgreen}%d{default}）",
		attacker, tag, victim, amount, newHp, maxHp);
}

// =============================================================================
//                              强制倒地（incap）
//   参考 rygive.sp line 940-974
// =============================================================================
void IncapTaker(int client)
{
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return;

	static ConVar cv;
	if (!cv) cv = FindConVar("survivor_max_incapacitated_count");
	int maxStrikes = cv.IntValue;
	if (maxStrikes < 1) maxStrikes = 1;

	// 若已濒死，先重置击倒数避免直接死亡
	if (GetEntProp(client, Prop_Send, "m_currentReviveCount") >= maxStrikes)
	{
		SetEntProp(client, Prop_Send, "m_currentReviveCount", maxStrikes - 1);
		SetEntProp(client, Prop_Send, "m_isGoingToDie", 0);
		SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 0);
		StopSound(client, SNDCHAN_STATIC, "player/heartbeatloop.wav");
	}

	Vulnerable(client);
	SetEntityHealth(client, 1);
	L4D_SetPlayerTempHealth(client, 0);
	SDKHooks_TakeDamage(client, 0, 0, 100.0, DMG_GENERIC);
}

// 取消无敌帧（参考 rygive line 967-974）
void Vulnerable(int client)
{
	static int m_invulnerabilityTimer = -1;
	if (m_invulnerabilityTimer == -1)
		m_invulnerabilityTimer = FindSendPropInfo("CTerrorPlayer", "m_noAvoidanceTimer") - 12;

	SetEntDataFloat(client, m_invulnerabilityTimer + 4, 0.0);
	SetEntDataFloat(client, m_invulnerabilityTimer + 8, 0.0);
}

// =============================================================================
//                              Idle Survivor Bot 查找
//   参考 rygive.sp line 1896-1909
// =============================================================================
int GetBotOfIdlePlayer(int client)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && GetIdlePlayerOfBot(i) == client)
			return i;
	}
	return 0;
}

int GetIdlePlayerOfBot(int client)
{
	if (!HasEntProp(client, Prop_Send, "m_humanSpectatorUserID"))
		return 0;

	return GetClientOfUserId(GetEntProp(client, Prop_Send, "m_humanSpectatorUserID"));
}

// =============================================================================
//                              StatsConditionPatch
//   参考 rygive.sp line 2224-2254
// =============================================================================
void InitGameData()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof sPath, "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(sPath))
	{
		LogError("未找到 gamedata 文件 %s，StatsConditionPatch 将不可用", sPath);
		return;
	}

	GameData hGameData = new GameData(GAMEDATA);
	if (!hGameData)
	{
		LogError("加载 gamedata %s 失败", GAMEDATA);
		return;
	}

	int iOffset = hGameData.GetOffset("RoundRespawn_Offset");
	if (iOffset == -1)
	{
		LogError("Missing offset: RoundRespawn_Offset");
		delete hGameData;
		return;
	}

	int iByteMatch = hGameData.GetOffset("RoundRespawn_Byte");
	if (iByteMatch == -1)
	{
		LogError("Missing offset: RoundRespawn_Byte");
		delete hGameData;
		return;
	}

	g_pStatsCondition = hGameData.GetMemSig("CTerrorPlayer::RoundRespawn");
	if (!g_pStatsCondition)
	{
		LogError("Missing signature: CTerrorPlayer::RoundRespawn");
		delete hGameData;
		return;
	}

	g_pStatsCondition += view_as<Address>(iOffset);
	int iByteOrigin = LoadFromAddress(g_pStatsCondition, NumberType_Int8);
	if (iByteOrigin != iByteMatch)
	{
		LogError("gamedata byte mismatch @ %d (0x%02X != 0x%02X)", iOffset, iByteOrigin, iByteMatch);
		g_pStatsCondition = Address_Null;
	}
	delete hGameData;
}

void StatsConditionPatch(bool patch)
{
	if (g_pStatsCondition == Address_Null)
		return; // gamedata 没加载成功，跳过

	if (!g_bStatsPatched && patch)
	{
		g_bStatsPatched = true;
		StoreToAddress(g_pStatsCondition, 0xEB, NumberType_Int8);
	}
	else if (g_bStatsPatched && !patch)
	{
		g_bStatsPatched = false;
		StoreToAddress(g_pStatsCondition, 0x75, NumberType_Int8);
	}
}