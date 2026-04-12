using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System;
using System.IO;
using TMPro;

public class StartNewGameButtonScript : MonoBehaviour, IPointerDownHandler
{
    Button button;
    TMP_InputField playerNameInput;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
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
        GameControllerScript.Instance.StartMission("Beginnings", 3, "Camp at the Crossroads");
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        Transform verticalLayout = this.transform.parent;
        Transform nameInput = verticalLayout.Find("New Player Name Input");
        if (nameInput != null)
        {
            playerNameInput = nameInput.GetComponent<TMP_InputField>();
        }
    }
}
