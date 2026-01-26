using UnityEngine;
using UnityEngine.UI;
using System.IO;

public class ContinueGameButtonScript : MonoBehaviour
{
    Button button;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound();
#if !UNITY_WEBGL || UNITY_EDITOR
        // Only load from file in non-WebGL builds
        PlayerDataScript.Instance.LoadPlayerData("Autosave");
#endif
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            GameControllerScript.Instance.StartMission("Beginnings", 3, "Camp at the Crossroads");
        }
        else
        {
            GameControllerScript.Instance.EnterHub(PlayerDataScript.Instance.lastHub);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);

#if UNITY_WEBGL && !UNITY_EDITOR
        // In WebGL, check if PlayerDataScript has valid data in memory
        if (PlayerDataScript.Instance == null || string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            this.gameObject.SetActive(false);
        }
#else
        // check if autosave file exists
        string autosavePath = Application.persistentDataPath + "/Autosave.txt";
        if (!File.Exists(autosavePath))
        {
            this.gameObject.SetActive(false);
        }
#endif
    }
}
