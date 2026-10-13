#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

#define PLUGIN_NAME "Hello"
#define PLUGIN_AUTHOR "InsectMk"
#define PLUGIN_DESCRIPTION "聊天框输入 !hello 或控制台输入 sm_hello 后向全服公屏打印 Hello World!"
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
    RegConsoleCmd("sm_hello", cmdHello, "向全服公屏打印 Hello World!");
}

public Action cmdHello(int client, int args) {
    PrintToChatAll("Hello World!");
    return Plugin_Handled;
}

// 实现此 forward 即可自动接收聊天框中的 !hello / @hello，无需手动注册
public Action OnPlayerCommandChat(int client, int command, const char[] args) {
    return cmdHello(client, 0);
}