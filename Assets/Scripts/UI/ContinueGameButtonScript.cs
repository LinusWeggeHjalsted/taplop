using UnityEngine;
using UnityEngine.UI;
using System.IO;

public class ContinueGameButtonScript : MonoBehaviour
{
    Button button;

    public void OnActivate()
    {
        PlayerDataScript.Instance.LoadPlayerData("Autosave");
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            GameControllerScript.Instance.StartMission("Beginnings", 3, "TestHub");
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
        // hide button in WebGL builds
        this.gameObject.SetActive(false);
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
