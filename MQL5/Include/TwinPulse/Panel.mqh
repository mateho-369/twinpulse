//+------------------------------------------------------------------+
//|                                                  Panel.mqh        |
//|  TwinPulse Hedge EA                                                 |
//|  On chart panel with the state of the EA, the legs and the brakes. |
//+------------------------------------------------------------------+
#pragma once

#include "Config.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "State.mqh"
#include "Execution.mqh"
#include "Risk.mqh"
#include "Regime.mqh"
#include "News.mqh"

#define TP_PANEL_BG   TP_PANEL_PREFIX + "BG"
#define TP_PANEL_TXT  TP_PANEL_PREFIX + "TXT"

//+------------------------------------------------------------------+
//| TP_Panel_Init - create the panel objects                           |
//+------------------------------------------------------------------+
void TP_Panel_Init(void)
  {
   if(!ShowPanel) return;

   if(ObjectFind(0, TP_PANEL_BG) < 0)
      ObjectCreate(0, TP_PANEL_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   if(ObjectFind(0, TP_PANEL_TXT) < 0)
      ObjectCreate(0, TP_PANEL_TXT, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_YDISTANCE, 8);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_BACK, false);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_ZORDER, 0);

   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_XDISTANCE, 14);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_YDISTANCE, 12);
   ObjectSetString(0, TP_PANEL_TXT, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_FONTSIZE, PanelFontSize);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_ZORDER, 1);
  }

//+------------------------------------------------------------------+
//| TP_Panel_Release - remove the panel objects                        |
//+------------------------------------------------------------------+
void TP_Panel_Release(void)
  {
   ObjectDelete(0, TP_PANEL_BG);
   ObjectDelete(0, TP_PANEL_TXT);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| TP_Panel_LegLine - one line per leg                                 |
//+------------------------------------------------------------------+
string TP_Panel_LegLine(const int legIndex)
  {
   if(!g_tp.legs[legIndex].open)
      return StringFormat("  %-7s   --   closed", TP_LegName(legIndex));

   return StringFormat("  %-7s %+7.2f  %0.2f lots  gen %d",
                       TP_LegName(legIndex),
                       g_tp.legs[legIndex].profit,
                       g_tp.legs[legIndex].volume,
                       g_tp.legs[legIndex].generation);
  }

//+------------------------------------------------------------------+
//| TP_Panel_Update - redraw the panel                                 |
//+------------------------------------------------------------------+
void TP_Panel_Update(void)
  {
   if(!ShowPanel) return;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double free     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double mlevel   = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double spread   = TP_Exec_CurrentSpreadPrice();
   double maxSpread= TP_Risk_MaxSpreadPrice();
   double daily    = equity - g_tp.dayStartEquity;

   string modeName = "FULL";
   if(TP_IsPureIdea()) modeName = "PURE_IDEA";
   if(TP_IsOneSide())  modeName = "ONE_SIDE";

   string brakeText = "OK";
   if(g_tp.dailyLocked)  brakeText = "DAILY STOP";
   if(g_tp.basketLocked) brakeText = "BASKET STOP";
   if(!g_tp.tradeAllowed) brakeText = "NO TRADING";

   int cooldown = 0;
   if(g_tp.lastReopen > 0)
     {
      int left = ReopenCooldownSec - (int)(TimeCurrent() - g_tp.lastReopen);
      if(left > 0) cooldown = left;
     }

   string text = "";
   text += StringFormat("%s %s | %s | cycle %d\n", TP_NAME, TP_VER, modeName, g_tp.cycleId);
   text += StringFormat("%s  magic %d  %s\n", g_symbol, (int)g_magic,
                        TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   text += StringFormat("regime %-9s spread %.3f/%.3f  ATR5 %.3f  ATR15 %.3f\n",
                        TP_RegimeName(g_tp.regime), spread, maxSpread, g_tp.atr5, g_tp.atrM15);
   text += "legs\n";
   for(int i = 0; i < TP_LEG_COUNT; i++)
      text += TP_Panel_LegLine(i) + "\n";
   text += StringFormat("floating %+.2f  realized %+.2f  bank %.2f  shredded %.2f\n",
                        TP_State_AllFloating(), g_tp.cycleRealized, g_tp.bank, g_tp.cycleShredded);
   text += StringFormat("daily %+.2f  equity %.2f  balance %.2f\n", daily, equity, balance);
   text += StringFormat("brakes %-10s margin %.0f%% free %.2f\n", brakeText, mlevel, free);
   text += StringFormat("swaps ~%.2f/night (%s)  news %s  cooldown %ds\n",
                        TP_Risk_SwapEstimate(), TP_Risk_SwapModeText(),
                        TP_News_Status(), cooldown);
   if(!g_tp.tradeAllowed)
      text += StringFormat("!! %s\n", g_tp.blockReason);

   ObjectSetString(0, TP_PANEL_TXT, OBJPROP_TEXT, text);

   int lines = 12;
   int width = 470;
   int height = lines * (PanelFontSize + 3) + 10;

   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, TP_PANEL_BG, OBJPROP_BGCOLOR,
                    g_tp.tradeAllowed ? clrBlack : clrMaroon);
   ObjectSetInteger(0, TP_PANEL_TXT, OBJPROP_COLOR,
                    g_tp.tradeAllowed ? clrSilver : clrWhite);

   ChartRedraw(0);
  }
