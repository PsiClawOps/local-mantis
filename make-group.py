import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("tud", "scripts/e2e/telegram-user-driver.py")
tud = importlib.util.module_from_spec(spec); spec.loader.exec_module(tud)
config, bot_config = tud.load_config()
d = tud.UserDriver(config, bot_config)
d.authorize()
def req(p, t=25):
    r = d.client.request(p, timeout=t)
    if isinstance(r, dict) and r.get("@type") == "error":
        print("ERR", p.get("@type"), r.get("message")); 
    return r
# 1) create supergroup
chat = req({"@type":"createNewSupergroupChat","title":"OpenClaw Mantis Proof","is_channel":False,"description":"local mantis telegram-desktop-proof group","message_auto_delete_time":0,"for_import":False})
gid = chat.get("id") if isinstance(chat, dict) else None
print("SUPERGROUP_ID", gid)
# 2) resolve the bot username -> user id (private-chat id == user id)
bot = req({"@type":"searchPublicChat","username":"JeeevesOpenClawTelegram2bot"})
bot_uid = bot.get("id") if isinstance(bot, dict) else None
print("BOT_UID", bot_uid)
# 3) add the bot (try 1.8.0 signature, then newer member_id form)
if gid and bot_uid:
    r = req({"@type":"addChatMember","chat_id":gid,"user_id":bot_uid,"forward_limit":0})
    if isinstance(r, dict) and r.get("@type")=="error":
        r = req({"@type":"addChatMember","chat_id":gid,"member_id":{"@type":"messageSenderUser","user_id":bot_uid},"forward_limit":0})
    print("ADD_BOT", r.get("@type") if isinstance(r,dict) else r)
    # 4) promote bot to admin so it sees all group messages (no @mention needed)
    rights={"@type":"chatAdministratorRights","can_manage_chat":True,"can_change_info":False,"can_post_messages":True,"can_edit_messages":True,"can_delete_messages":True,"can_invite_users":True,"can_restrict_members":False,"can_pin_messages":True,"can_promote_members":False,"can_manage_video_chats":False,"is_anonymous":False}
    pr = req({"@type":"setChatMemberStatus","chat_id":gid,"member_id":{"@type":"messageSenderUser","user_id":bot_uid},"status":{"@type":"chatMemberStatusAdministrator","custom_title":"bot","can_be_edited":True,"rights":rights}})
    print("PROMOTE_BOT", pr.get("@type") if isinstance(pr,dict) else pr)
print("DONE")
