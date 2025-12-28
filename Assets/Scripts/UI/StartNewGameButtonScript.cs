using UnityEngine;
using UnityEngine.UI;
using System;
using System.IO;
using TMPro;

public class StartNewGameButtonScript : MonoBehaviour
{
    Button button;
    TMP_InputField playerNameInput;
    TMP_InputField playerSeedInput;

    public void OnActivate()
    {
#if !UNITY_WEBGL || UNITY_EDITOR
        // backup existing Autosave if it exists
        string autosavePath = Application.persistentDataPath + "/Autosave.txt";
        if (File.Exists(autosavePath))
        {
            DateTime fileTime = File.GetLastWriteTime(autosavePath);
            string timestamp = fileTime.ToString("yyyy-MM-dd_HH-mm-ss");
            string backupPath = Application.persistentDataPath + "/Autosave_" + timestamp + ".txt";
            try
            {
                File.Copy(autosavePath, backupPath);
            }
            catch (Exception e)
            {
                Debug.LogError("Failed to backup autosave: " + e.Message);
            }
        }
#endif
        PlayerDataScript.Instance.LoadPlayerData("New Game");
        if (playerNameInput != null && !string.IsNullOrEmpty(playerNameInput.text))
        {
            PlayerDataScript.Instance.playerName = playerNameInput.text;
        }
        if (playerSeedInput != null && !string.IsNullOrEmpty(playerSeedInput.text))
        {
            int seed;
            if (int.TryParse(playerSeedInput.text, out seed))
            {
                PlayerDataScript.Instance.randomSeed = seed;
            }
            else
            {
                PlayerDataScript.Instance.randomSeed = new System.Random().Next();
            }
        }
        else
        {
            PlayerDataScript.Instance.randomSeed = new System.Random().Next();
        }
        GameControllerScript.Instance.StartMission("Beginnings", 3, "Camp at the Crossroads");
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        Transform verticalLayout = this.transform.parent;
        Transform nameInput = verticalLayout.Find("New Player Name Input");
        Transform seedInput = verticalLayout.Find("New Player Seed Input");
        if (nameInput != null)
        {
            playerNameInput = nameInput.GetComponent<TMP_InputField>();
        }
        if (seedInput != null)
        {
            playerSeedInput = seedInput.GetComponent<TMP_InputField>();
        }
    }
}
