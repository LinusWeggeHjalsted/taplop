using UnityEngine;
using UnityEngine.UI;

public class ExitMissionButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound();
        GameObject player = GameObject.Find("Player");
        if (player != null)
        {
            PlayerDataScript.Instance.BuildDataFromPlayer(player);
        }
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            GameControllerScript.Instance.MainMenu();
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

        GameObject missionLogic = GameObject.Find("Mission Logic");
        if (missionLogic == null)
        {
            this.gameObject.SetActive(false);
        }
    }
}
