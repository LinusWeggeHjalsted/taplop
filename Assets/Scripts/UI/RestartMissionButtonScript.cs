using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class RestartMissionButtonScript : MonoBehaviour, IPointerDownHandler
{
    public Button button;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
        GameObject player = GameReferences.GetPlayer();
        if (player != null)
        {
            PlayerDataScript.Instance.BuildDataFromPlayer(player);
        }
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        string missionName = MissionLogicScript.Instance.missionName;
        int missionLength = MissionLogicScript.Instance.missionLength;
        string endHub = MissionLogicScript.Instance.endHub;
        GameControllerScript.Instance.StartMission(missionName, missionLength, endHub);
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
