using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System.IO;

public class ContinueGameButtonScript : MonoBehaviour, IPointerDownHandler
{
    Button button;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
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
        if (PlayerDataScript.Instance == null || PlayerDataScript.Instance.turns == 0)
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
