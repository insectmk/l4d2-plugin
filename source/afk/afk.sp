#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <left4dhooks>
#include <multicolors>

#define PLUGIN_NAME "AFK Command"
#define PLUGIN_AUTHOR "InsectMk"
#define PLUGIN_DESCRIPTION "闲置功能插件"
#define PLUGIN_VERSION "1.0"
#define PLUGIN_URL ""

public Plugin myinfo = {
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

public void OnPluginStart() {
    RegConsoleCmd("sm_afk", cmdAFK, "闲置当前玩家");
    RegConsoleCmd("sm_idle", cmdAFK, "闲置当前玩家"); // 别名
    RegConsoleCmd("sm_rest", cmdAFK, "闲置当前玩家"); // 别名
}

Action cmdAFK(int client, int args) {
    if (!client || !IsClientInGame(client)) {
        return Plugin_Handled;
    }
    
    // 检查玩家是否已经是生还者
    if (GetClientTeam(client) != 2) {
        CReplyToCommand(client, "{default}[{green}AFK{default}] {red}只有生还者才能进行闲置!");
        return Plugin_Handled;
    }
    
    // 检查玩家是否已经闲置
    if (GetBotOfIdlePlayer(client) > 0) {
        CReplyToCommand(client, "{default}[{green}AFK{default}] {red}你已经处于闲置状态!");
        return Plugin_Handled;
    }
    
    // 执行闲置
    GoAFKTimer(client, 0.0);
    CReplyToCommand(client, "{default}[{green}AFK{default}] {olive}你已进入闲置状态!");
    
    // 向所有玩家广播闲置消息（彩色）
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) != 3) {
            CPrintToChat(i, "{default}[{green}AFK{default}] {olive}%N {default}已进入闲置状态", client);
        }
    }
    
    return Plugin_Handled;
}

// 设置玩家闲置计时器
void GoAFKTimer(int client, float flDuration) {
    static int m_GoAFKTimer = -1;
    if (m_GoAFKTimer == -1) {
        m_GoAFKTimer = FindSendPropInfo("CTerrorPlayer", "m_lookatPlayer") - 12;
    }
    
    SetEntDataFloat(client, m_GoAFKTimer + 4, flDuration);
    SetEntDataFloat(client, m_GoAFKTimer + 8, GetGameTime() + flDuration);
}

// 获取玩家的闲置机器人
int GetBotOfIdlePlayer(int client) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && GetIdlePlayerOfBot(i) == client) {
            return i;
        }
    }
    return 0;
}

// 获取机器人的闲置玩家
int GetIdlePlayerOfBot(int client) {
    if (!HasEntProp(client, Prop_Send, "m_humanSpectatorUserID")) {
        return 0;
    }
    return GetClientOfUserId(GetEntProp(client, Prop_Send, "m_humanSpectatorUserID"));
}