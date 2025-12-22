using UnityEngine;
using UnityEngine.UI;
using System.Runtime.InteropServices;

public class LoadSaveButtonScript : MonoBehaviour
{
    Button button;

#if UNITY_WEBGL && !UNITY_EDITOR
    [DllImport("__Internal")]
    private static extern void UploadFile(string gameObjectName, string callbackMethodName);
#endif

    public void OnActivate()
    {
#if UNITY_WEBGL && !UNITY_EDITOR
        // in WebGL, prompt user to upload a save file
        UploadFile(gameObject.name, "OnFileUploaded");
#else
        // in standalone builds, load from file system
        // to-do: implement file picker for standalone builds
        Debug.LogWarning("Load Save not yet implemented for standalone builds");
#endif
    }

    public void OnFileUploaded(string fileContent)
    {
        PlayerDataScript.Instance.LoadPlayerDataFromText(fileContent);
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
    }
}
