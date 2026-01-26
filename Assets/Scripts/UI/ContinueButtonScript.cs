using UnityEngine;
using UnityEngine.UI;

public class ContinueButtonScript : MonoBehaviour
{
    public Button button;
    public GameObject optionsMenu;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound();
        Destroy(optionsMenu);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        optionsMenu = GameObject.Find("Options Menu(Clone)");
    }
}
