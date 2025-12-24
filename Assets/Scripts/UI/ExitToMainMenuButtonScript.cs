using UnityEngine;
using UnityEngine.UI;

public class ExitToMainMenuButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        GameObject player = GameObject.Find("Player");
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        GameControllerScript.Instance.MainMenu();
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
