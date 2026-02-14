using UnityEngine;
using TMPro;
using System.Collections.Generic;

public class MissionCompletionScreenScript : MonoBehaviour
{
    public TMP_Text missionCompletionHeaderText;
    public GameObject newCloneInfoPanel;
    public TMP_Text newCloneInfoText;
    public TMP_Text existingCloneInfoText;
    public TMP_Text combatInfoText;
    public GameObject cloneRunPanel;
    public TMP_Text cloneRunBodyText;

    public void GetInfo()
    {
        MissionLogicScript missionLogicScript = MissionLogicScript.Instance;
        string missionName = missionLogicScript.missionName;
        int totalTurns = missionLogicScript.totalTurns;
        missionCompletionHeaderText.text = $"{missionName} completed in {totalTurns} turns";
        
        // automatically save a clone if first time completing mission
        PlayerDataScript.Salvage totalSalvage = missionLogicScript.totalSalvage;
        if (!PlayerDataScript.Instance.allCloneData.ContainsKey(missionName))
        {
            newCloneInfoPanel.SetActive(false);
            PlayerDataScript.CloneData newCloneData = new PlayerDataScript.CloneData();
            newCloneData.totalSalvage = totalSalvage;
            newCloneData.turnsToComplete = totalTurns;
            PlayerDataScript.Instance.allCloneData.Add(missionName, newCloneData);
        }
        else
        {
            float newWoodPerTurn = (float)totalSalvage.wood / (float)totalTurns;
            float newMetalPerTurn = (float)totalSalvage.metal / (float)totalTurns;
            float newLeatherPerTurn = (float)totalSalvage.leather / (float)totalTurns;
            float newClothPerTurn = (float)totalSalvage.cloth / (float)totalTurns;
            float newKnowledgePerTurn = (float)totalSalvage.knowledge / (float)totalTurns;
            newCloneInfoText.text = $"New clone gathers {newWoodPerTurn:F2} wood, {newMetalPerTurn:F2} metal, {newLeatherPerTurn:F2} leather, {newClothPerTurn:F2} cloth, {newKnowledgePerTurn:F2} knowledge per turn";

            PlayerDataScript.CloneData existingCloneData = PlayerDataScript.Instance.allCloneData[missionName];
            PlayerDataScript.Salvage existingTotalSalvage = existingCloneData.totalSalvage;
            int existingTotalTurns = existingCloneData.turnsToComplete;
            float existingWoodPerTurn = (float)existingTotalSalvage.wood / (float)existingTotalTurns;
            float existingMetalPerTurn = (float)existingTotalSalvage.metal / (float)existingTotalTurns;
            float existingLeatherPerTurn = (float)existingTotalSalvage.leather / (float)existingTotalTurns;
            float existingClothPerTurn = (float)existingTotalSalvage.cloth / (float)existingTotalTurns;
            float existingKnowledgePerTurn = (float)existingTotalSalvage.knowledge / (float)existingTotalTurns;
            existingCloneInfoText.text = $"Existing clone gathers {existingWoodPerTurn:F2} wood, {existingMetalPerTurn:F2} metal, {existingLeatherPerTurn:F2} leather, {existingClothPerTurn:F2} cloth, {existingKnowledgePerTurn:F2} knowledge per turn";            
        }

        // display combat stats
        int totalKills = missionLogicScript.totalKills;
        int totalUsedSkills = missionLogicScript.totalUsedSkills;
        int totalOutgoingDamage = missionLogicScript.totalOutgoingDamage;
        int totalIncomingDamage = missionLogicScript.totalIncomingDamage;
        float killsPerTurn = (float)totalKills / (float)totalTurns;
        float usedSkillsPerTurn = (float)totalUsedSkills / (float)totalTurns;
        float outgoingDamagePerTurn = (float)totalOutgoingDamage / (float)totalTurns;
        float incomingDamagePerTurn = (float)totalIncomingDamage / (float)totalTurns;
        combatInfoText.text = $"{killsPerTurn:F2} kills per turn ({totalKills} total)\n{outgoingDamagePerTurn:F2} outgoing damage per turn ({totalOutgoingDamage} total)\n{incomingDamagePerTurn:F2} incoming damage per turn ({totalIncomingDamage} total)";

        // display clone run rewards if there are any saved clone runs other than this mission
        if (PlayerDataScript.Instance.allCloneData.Count <= 1)
        {
            cloneRunPanel.SetActive(false);
        }
        else
        {
            Dictionary<string, PlayerDataScript.CloneData> allCloneData = PlayerDataScript.Instance.allCloneData;
            string allCloneText = "";
            foreach (string cloneMission in allCloneData.Keys)
            {
                if (cloneMission == missionName)
                {
                    continue;
                }
                PlayerDataScript.CloneData cloneData = allCloneData[cloneMission];
                PlayerDataScript.Salvage cloneTotalSalvage = cloneData.totalSalvage;
                int cloneTotalTurns = cloneData.turnsToComplete;
                int gatheredWood = cloneTotalSalvage.wood * totalTurns / cloneTotalTurns;
                int gatheredMetal = cloneTotalSalvage.metal * totalTurns / cloneTotalTurns;
                int gatheredLeather = cloneTotalSalvage.leather * totalTurns / cloneTotalTurns;
                int gatheredCloth = cloneTotalSalvage.cloth * totalTurns / cloneTotalTurns;
                int gatheredKnowledge = cloneTotalSalvage.knowledge * totalTurns / cloneTotalTurns;
                allCloneText += $"{cloneMission} - {gatheredWood} wood, {gatheredMetal} metal, {gatheredLeather} leather, {gatheredCloth} cloth, {gatheredKnowledge} knowledge\n";
                // give clone run rewards to player
                PlayerDataScript.Salvage cloneSalvage = new PlayerDataScript.Salvage();
                cloneSalvage.wood = gatheredWood;
                cloneSalvage.metal = gatheredMetal;
                cloneSalvage.leather = gatheredLeather;
                cloneSalvage.cloth = gatheredCloth;
                cloneSalvage.knowledge = gatheredKnowledge;
                PlayerDataScript.Instance.collectedSalvage += cloneSalvage;
            }
            cloneRunBodyText.text = allCloneText;
        }
    }

    void Start()
    {
        SoundControllerScript.Instance.PlayMissionCompletionSound();
        missionCompletionHeaderText = this.transform.Find("Canvas/Background Panel/Mission Completion Header Text").GetComponent<TMP_Text>();
        newCloneInfoPanel = this.transform.Find("Canvas/Background Panel/New Clone Info Panel").gameObject;
        newCloneInfoText = this.transform.Find("Canvas/Background Panel/New Clone Info Panel/Vertical Layout/New Clone Info Text").GetComponent<TMP_Text>();
        existingCloneInfoText = this.transform.Find("Canvas/Background Panel/New Clone Info Panel/Vertical Layout/Existing Clone Info Text").GetComponent<TMP_Text>();
        combatInfoText = this.transform.Find("Canvas/Background Panel/Horizontal Layout/Vertical Layout/Combat Info Text").GetComponent<TMP_Text>();
        cloneRunPanel = this.transform.Find("Canvas/Background Panel/Horizontal Layout/Clone Run Panel").gameObject;
        cloneRunBodyText = this.transform.Find("Canvas/Background Panel/Horizontal Layout/Clone Run Panel/Clone Run Body Text").GetComponent<TMP_Text>();
        GetInfo();
    }
}
